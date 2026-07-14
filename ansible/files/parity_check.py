"""Live-vs-backtest parity monitor.

For every deployed portfolio, replays the last days of broker bars through
each leg's signal code and diffs the simulated entry signals against the
actual live fills (attributed via order magic numbers).

The key parity number is live coverage: every live entry must correspond to
a backtest signal on the same bar with the same direction ("extra" live
entries indicate an execution bug and raise an alert). Signals with no live
fill ("missed") are informational — the engine legitimately skips entries
while a position is open or a risk guard is active.

Runs inside the portfolio-lab backend container (python - < this file) and
prints a JSON report to stdout.
"""

from __future__ import annotations

import inspect
import json
import sys
from datetime import datetime, timedelta, timezone

from sqlmodel import Session, select

from app.api.routes.portfolios import load_strategy_instances
from app.backtesting.data.provider import get_market_data
from app.backtesting.engine.backtest_engine import STRATEGIES
from app.backtesting.strategies.builtin import is_builtin_strategy_key
from app.backtesting.strategies.custom import compile_strategy_function
from app.core.db import engine as db_engine
from app.models import Portfolio, StrategyDefinition
from app.portfolio.deployment import get_execution_node_client
from app.portfolio.strategy_source import prepare_strategy_source_for_execution_node

WINDOW_DAYS = 7
TF_SECONDS = {
    "1m": 60, "5m": 300, "15m": 900, "30m": 1800,
    "1h": 3600, "2h": 7200, "4h": 14400, "1d": 86400,
}
MATCH_EARLY_SLACK = 120  # seconds before bar close a fill may print
MATCH_LATE_SLACK_MIN = 600  # engine ticks may lag the bar close


def strip_imports(source: str) -> str:
    prepared = prepare_strategy_source_for_execution_node(source)
    return "\n".join(
        line
        for line in prepared.splitlines()
        if not line.lstrip().startswith(("import ", "from "))
    )


def resolve_signal_function(session: Session, strategy_key: str):
    if is_builtin_strategy_key(strategy_key):
        return STRATEGIES[strategy_key].generate_signals
    definition = session.get(StrategyDefinition, strategy_key)
    if definition is None:
        raise ValueError(f"Strategy definition not found: {strategy_key}")
    return compile_strategy_function(strip_imports(definition.code))


def filter_params(fn, params: dict) -> dict:
    signature = inspect.signature(fn)
    if any(
        p.kind == inspect.Parameter.VAR_KEYWORD
        for p in signature.parameters.values()
    ):
        return dict(params)
    return {k: v for k, v in params.items() if k in signature.parameters}


def to_epoch(ts) -> float:
    dt = ts.to_pydatetime() if hasattr(ts, "to_pydatetime") else ts
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def main() -> None:
    now = datetime.now(timezone.utc)
    since = now - timedelta(days=WINDOW_DAYS)
    client = get_execution_node_client()
    report = {
        "generated_at": now.isoformat(),
        "window_days": WINDOW_DAYS,
        "deployments": {},
        "alerts": [],
    }
    alerts = report["alerts"]

    with Session(db_engine) as session:
        portfolios = session.exec(
            select(Portfolio).where(Portfolio.execution_portfolio_id != None)  # noqa: E711
        ).all()
        for portfolio in portfolios:
            pid = portfolio.execution_portfolio_id
            try:
                deals_payload = client.get_deployment_deals(
                    execution_portfolio_id=pid, since=since.isoformat()
                )
            except Exception as error:  # noqa: BLE001
                alerts.append(f"deployment {pid}: deals fetch failed: {error}")
                continue
            deals = deals_payload.get("deals", [])
            legs_out = []
            for instance in load_strategy_instances(session, portfolio.id):
                if not instance.enabled:
                    continue
                leg = {
                    "strategy_key": instance.strategy_key,
                    "symbol": instance.symbol,
                    "timeframe": instance.timeframe,
                }
                live_entries = [
                    d
                    for d in deals
                    if d.get("instance_id") == str(instance.id)
                    and d.get("entry") == "in"
                ]
                try:
                    fn = resolve_signal_function(session, instance.strategy_key)
                    data = get_market_data(
                        instance.symbol,
                        (since - timedelta(days=30)).date().isoformat(),
                        (now + timedelta(days=1)).date().isoformat(),
                        instance.timeframe,
                        use_broker_data=True,
                    )
                    result = fn(data, **filter_params(fn, instance.strategy_params))
                    signals = []
                    for key, direction in (
                        ("long_entries", "buy"),
                        ("short_entries", "sell"),
                    ):
                        series = result.get(key)
                        if series is None:
                            continue
                        for ts in series[series.astype(bool)].index:
                            if to_epoch(ts) >= since.timestamp():
                                signals.append((to_epoch(ts), direction))
                except Exception as error:  # noqa: BLE001
                    leg["error"] = str(error)[:200]
                    alerts.append(
                        f"deployment {pid} {instance.strategy_key} "
                        f"{instance.symbol}: replay failed: {str(error)[:120]}"
                    )
                    legs_out.append(leg)
                    continue

                tf_seconds = TF_SECONDS.get(instance.timeframe, 3600)
                late_slack = max(MATCH_LATE_SLACK_MIN, tf_seconds // 2)
                unmatched_live = list(live_entries)
                matched = 0
                for bar_open, direction in sorted(signals):
                    bar_close = bar_open + tf_seconds
                    hit = None
                    for deal in unmatched_live:
                        deal_epoch = datetime.fromisoformat(deal["time"]).timestamp()
                        if deal["side"] == direction and (
                            bar_close - MATCH_EARLY_SLACK
                            <= deal_epoch
                            <= bar_close + late_slack
                        ):
                            hit = deal
                            break
                    if hit is not None:
                        unmatched_live.remove(hit)
                        matched += 1

                leg.update(
                    {
                        "simulated_signals": len(signals),
                        "live_entries": len(live_entries),
                        "matched": matched,
                        "missed_signals": len(signals) - matched,
                        "extra_live_entries": [
                            {
                                "time": d["time"],
                                "side": d["side"],
                                "price": d.get("price"),
                            }
                            for d in unmatched_live
                        ],
                    }
                )
                if unmatched_live:
                    alerts.append(
                        f"deployment {pid} {instance.strategy_key} "
                        f"{instance.symbol} {instance.timeframe}: "
                        f"{len(unmatched_live)} live entries with NO matching "
                        "backtest signal"
                    )
                legs_out.append(leg)

            total_live = sum(leg.get("live_entries", 0) for leg in legs_out)
            total_matched = sum(leg.get("matched", 0) for leg in legs_out)
            report["deployments"][str(pid)] = {
                "portfolio": portfolio.name,
                "legs": legs_out,
                "live_entries": total_live,
                "live_entries_matched": total_matched,
            }

    report["ok"] = not alerts
    print(json.dumps(report, indent=1))
    sys.exit(0)


main()
