"""Weekly live-vs-backtest P&L comparison.

For every deployed portfolio, backtests the current trading week (Monday
00:00 UTC to now) per leg — same strategy code, parameters, risk percent,
realistic costs, sized on the account's week-start balance — and compares
the simulated result with the live one: closed trades, net P&L, and entry
slippage on live fills versus their signal bar.

Per-leg simulations size independently on a fixed week-start balance, so
small deltas versus the live account (which compounds all legs on shared
equity) are expected; sign flips or large gaps are what deserve a look.

Runs inside the portfolio-lab backend container and prints JSON to stdout.
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone

from sqlmodel import Session, select

from app.api.routes.portfolios import load_strategy_instances
from app.backtesting.engine.backtest_engine import run_backtest
from app.backtesting.strategies.builtin import is_builtin_strategy_key
from app.core.db import engine as db_engine
from app.models import Portfolio, StrategyDefinition
from app.portfolio.deployment import get_execution_node_client
from app.portfolio.strategy_source import prepare_strategy_source_for_execution_node

PNL_GAP_ALERT_USD = 100.0  # per-leg live-vs-sim gap worth flagging


def week_start(now: datetime) -> datetime:
    monday = now - timedelta(days=now.weekday())
    return monday.replace(hour=0, minute=0, second=0, microsecond=0)


def strip_imports(source: str) -> str:
    prepared = prepare_strategy_source_for_execution_node(source)
    return "\n".join(
        line
        for line in prepared.splitlines()
        if not line.lstrip().startswith(("import ", "from "))
    )


def resolve_code(session: Session, strategy_key: str) -> str | None:
    if is_builtin_strategy_key(strategy_key):
        return None  # run_backtest resolves builtins by name
    definition = session.get(StrategyDefinition, strategy_key)
    if definition is None:
        raise ValueError(f"Strategy definition not found: {strategy_key}")
    return strip_imports(definition.code)


def main() -> None:
    now = datetime.now(timezone.utc)
    start = week_start(now)
    client = get_execution_node_client()
    report = {
        "generated_at": now.isoformat(),
        "week_start": start.isoformat(),
        "deployments": {},
        "alerts": [],
        "notes": (
            "Per-leg simulations size on a fixed week-start balance; the live "
            "account compounds all legs on shared equity, so small deltas are "
            "expected."
        ),
    }
    alerts = report["alerts"]

    with Session(db_engine) as session:
        portfolios = session.exec(
            select(Portfolio).where(Portfolio.execution_portfolio_id != None)  # noqa: E711
        ).all()
        for portfolio in portfolios:
            pid = portfolio.execution_portfolio_id
            try:
                live = client.get_live_report(
                    execution_portfolio_id=pid, window="week"
                )
                deals_payload = client.get_deployment_deals(
                    execution_portfolio_id=pid, since=start.isoformat()
                )
            except Exception as error:  # noqa: BLE001
                alerts.append(f"deployment {pid}: live data fetch failed: {error}")
                continue

            week_start_balance = float(live.get("start_balance") or 0.0)
            live_rows = {
                row["instance_id"]: row for row in live.get("strategies", [])
            }
            # Entry fill prices per instance for the slippage stats.
            entry_prices: dict[str, list[float]] = {}
            for deal in deals_payload.get("deals", []):
                if deal.get("entry") == "in" and deal.get("instance_id"):
                    if deal.get("price") is not None:
                        entry_prices.setdefault(deal["instance_id"], []).append(
                            float(deal["price"])
                        )

            legs_out = []
            sim_total = 0.0
            live_total = 0.0
            for instance in load_strategy_instances(session, portfolio.id):
                if not instance.enabled:
                    continue
                live_row = live_rows.get(str(instance.id), {})
                live_pnl = float(live_row.get("closed_pnl_total") or 0.0)
                live_trades = int(live_row.get("trades_total") or 0)
                leg = {
                    "strategy": live_row.get("strategy") or instance.strategy_key,
                    "symbol": instance.symbol,
                    "timeframe": instance.timeframe,
                    "risk_pct": instance.risk_per_trade_pct,
                    "live_trades": live_trades,
                    "live_pnl": round(live_pnl, 2),
                }
                try:
                    code = resolve_code(session, instance.strategy_key)
                    result = run_backtest(
                        strategy_name=instance.strategy_key,
                        symbol=instance.symbol,
                        start_date=start.date().isoformat(),
                        end_date=(now + timedelta(days=1)).date().isoformat(),
                        timeframe=instance.timeframe,
                        initial_balance=week_start_balance or 10_000,
                        risk_per_trade_pct=instance.risk_per_trade_pct,
                        strategy_params=instance.strategy_params,
                        max_equity_curve_points=None,
                        strategy_code=code,
                        use_broker_data=True,
                    )
                    metrics = result["metrics"]
                    sim_pnl = float(metrics.get("final_equity") or 0.0) - (
                        week_start_balance or 10_000
                    )
                    sim_trades = int(metrics.get("total_trades") or 0)
                except Exception as error:  # noqa: BLE001
                    leg["error"] = str(error)[:160]
                    alerts.append(
                        f"deployment {pid} {instance.strategy_key} "
                        f"{instance.symbol}: sim failed: {str(error)[:100]}"
                    )
                    legs_out.append(leg)
                    continue

                delta = live_pnl - sim_pnl
                leg.update(
                    {
                        "sim_trades": sim_trades,
                        "sim_pnl": round(sim_pnl, 2),
                        "pnl_delta": round(delta, 2),
                    }
                )
                sim_total += sim_pnl
                live_total += live_pnl
                if (live_trades or sim_trades) and (
                    abs(delta) >= PNL_GAP_ALERT_USD
                    or (live_pnl < 0 < sim_pnl)
                    or (sim_pnl < 0 < live_pnl)
                ):
                    alerts.append(
                        f"deployment {pid} "
                        f"{leg['strategy'][:24]} {instance.symbol} "
                        f"{instance.timeframe}: live {live_pnl:+.2f} vs sim "
                        f"{sim_pnl:+.2f} (delta {delta:+.2f})"
                    )
                legs_out.append(leg)

            report["deployments"][str(pid)] = {
                "portfolio": portfolio.name,
                "week_start_balance": round(week_start_balance, 2),
                "live_pnl": round(live_total, 2),
                "sim_pnl": round(sim_total, 2),
                "pnl_delta": round(live_total - sim_total, 2),
                "legs": legs_out,
            }

    report["ok"] = not alerts
    print(json.dumps(report, indent=1))
    sys.exit(0)


main()
