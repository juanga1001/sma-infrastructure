"""Live-vs-backtest parity monitor.

For every deployed portfolio, replays the last days of broker bars through
each leg's signal code and diffs the simulated entry signals against the
actual live fills (attributed via order magic numbers).

The key parity number is live coverage: every live entry must correspond to
a backtest signal on the same bar with the same direction ("extra" live
entries indicate an execution bug and raise an alert). Signals with no live
fill ("missed") ALSO raise an alert since 2026-08-20: treating them as
informational hid a structural executor bug for a week (every intra-bar
touch entry silently lost while ok=true). A miss can still be legitimate
(position already open, risk guard) — the alert asks for a look, it does
not by itself mean a bug.

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
from app.portfolio.snapshot import (
    BROKER_DST_RULE,
    BROKER_WINTER_OFFSET_MIN,
    SESSION_ANCHORED_STRATEGIES,
)
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


def _last_sunday(year: int, month: int) -> datetime:
    day = datetime(year, month, 31)
    return day - timedelta(days=(day.weekday() + 1) % 7)


def utc_to_ny(ts: datetime) -> datetime:
    """True UTC -> New York (no broker-offset step)."""
    utc = ts.replace(tzinfo=None)
    mar14 = datetime(utc.year, 3, 14)
    nov7 = datetime(utc.year, 11, 7)
    dst_start = mar14 - timedelta(days=(mar14.weekday() + 1) % 7)
    dst_end = nov7 - timedelta(days=(nov7.weekday() + 1) % 7)
    in_dst = dst_start + timedelta(hours=7) <= utc < dst_end + timedelta(hours=6)
    return utc - timedelta(hours=4 if in_dst else 5)


def broker_to_ny(ts: datetime) -> datetime:
    """Broker wall time (engine labels server time as UTC) -> New York.

    Same arithmetic every session-anchored strategy inlines: EU DST rule
    for the broker offset, US DST for New York.
    """
    t = ts.replace(tzinfo=None)
    offset = BROKER_WINTER_OFFSET_MIN
    if str(BROKER_DST_RULE).upper() == "EU":
        on = _last_sunday(t.year, 3) + timedelta(hours=3)
        off = _last_sunday(t.year, 10) + timedelta(hours=4)
        if on <= t < off:
            offset += 60
    utc = t - timedelta(minutes=offset)
    mar14 = datetime(utc.year, 3, 14)
    nov7 = datetime(utc.year, 11, 7)
    dst_start = mar14 - timedelta(days=(mar14.weekday() + 1) % 7)
    dst_end = nov7 - timedelta(days=(nov7.weekday() + 1) % 7)
    in_dst = dst_start + timedelta(hours=7) <= utc < dst_end + timedelta(hours=6)
    return utc - timedelta(hours=4 if in_dst else 5)


# Session-flat legs must be closed by 15:55 NY; slack for fill latency.
SESSION_EXIT_DEADLINE_MIN = 16 * 60 + 10


def run_exit_parity(
    *,
    pid: int,
    client,
    deals: list,
    exit_meta: dict,
    alerts: list,
    now: datetime,
) -> dict:
    """Structural exit checks (2026-08-20: entry parity said nothing about
    exits while every winner was truncated at a fabricated 2R target).

    E1  session-flat legs must hold NOTHING outside session hours;
    E2  server-side levels must match the port's exit design (trailing
        or no-target ports carry NO take-profit, trailing carries a
        stop);
    E3  every session-leg round trip closes the same NY day, by the
        15:55 flat (+slack).
    Exit counts per leg stay informational — stop-outs make exact
    exit-time matching noisy, the structure is what must never drift.
    """
    summary = {"open_positions_checked": 0, "round_trips_checked": 0}

    try:
        live = client.get_live_report(execution_portfolio_id=pid, window="day")
        open_positions = live.get("open_positions") or []
    except Exception as error:  # noqa: BLE001
        alerts.append(f"deployment {pid}: exit-parity live fetch failed: {error}")
        return summary

    now_ny = utc_to_ny(now)  # `now` is real UTC, not broker wall time
    ny_minutes = now_ny.hour * 60 + now_ny.minute
    # Only enforce the flat check when every session (London + NY) is
    # closed; an ad-hoc daytime run must not flag in-session positions.
    markets_closed = not (3 * 60 <= ny_minutes <= SESSION_EXIT_DEADLINE_MIN)

    for position in open_positions:
        meta = exit_meta.get(str(position.get("instance_id")))
        if meta is None:
            continue
        summary["open_positions_checked"] += 1
        label = f"deployment {pid} {meta['key']} {position.get('symbol')}"
        sl = float(position.get("sl") or 0.0)
        tp = float(position.get("tp") or 0.0)
        if meta["session"] and markets_closed:
            alerts.append(
                f"{label}: session-flat leg holds an OPEN position outside "
                "session hours — the exit did not run"
            )
        if meta["trailing"]:
            if tp > 0.0:
                alerts.append(
                    f"{label}: trailing port carries a take-profit ({tp}) — "
                    "fabricated-target class"
                )
            if sl <= 0.0:
                alerts.append(f"{label}: trailing position has NO stop-loss")
        elif not meta["has_target"] and tp > 0.0:
            alerts.append(
                f"{label}: no-target port carries a take-profit ({tp}) — "
                "fabricated-target class"
            )

    entries_by_position = {
        d.get("position_id"): d
        for d in deals
        if d.get("entry") == "in" and d.get("position_id") is not None
    }
    for deal in deals:
        if deal.get("entry") != "out":
            continue
        meta = exit_meta.get(str(deal.get("instance_id")))
        if meta is None or not meta["session"]:
            continue
        entry_deal = entries_by_position.get(deal.get("position_id"))
        if entry_deal is None:
            continue
        summary["round_trips_checked"] += 1
        t_in = broker_to_ny(datetime.fromisoformat(entry_deal["time"]))
        t_out = broker_to_ny(datetime.fromisoformat(deal["time"]))
        label = (
            f"deployment {pid} {meta['key']} {deal.get('symbol')}"
        )
        if t_in.date() != t_out.date():
            alerts.append(
                f"{label}: session-flat round trip held OVERNIGHT "
                f"({t_in.date()} -> {t_out.date()})"
            )
        elif t_out.hour * 60 + t_out.minute > SESSION_EXIT_DEADLINE_MIN:
            alerts.append(
                f"{label}: round trip closed at {t_out.strftime('%H:%M')} NY, "
                "after the 15:55 session flat"
            )
    return summary


def main() -> None:
    now = datetime.now(timezone.utc)
    # Live-evidence epoch (see weekly_report.py): the executor missed
    # intra-bar entries and suppressed trailing-stop ports until the
    # 2026-08-20 ~12:15 UTC fixes. Pre-fix days are excluded so the
    # nightly alerts describe the FIXED system, not the diagnosed past.
    epoch = datetime(2026, 8, 20, 12, 15, tzinfo=timezone.utc)
    since = max(now - timedelta(days=WINDOW_DAYS), epoch)
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
            # Only portfolios the engine is actually running: an undeployed
            # (stopped) portfolio keeps its execution id and would otherwise
            # produce a nightly "fetch failed" alert forever (FTMO demo,
            # 2026-08-22).
            select(Portfolio).where(
                Portfolio.execution_portfolio_id != None,  # noqa: E711
                Portfolio.deployment_status == "running",
            )
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
            exit_meta = {}
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
                    # Session-anchored strategies read clock times off the
                    # bar index, and these sims run on BROKER bars (UTC+3
                    # summer / UTC+2 winter). Without the same offset the
                    # deployment injects, every session lands hours off and
                    # every live entry looks unmatched — 5 false ORB alerts
                    # on 2026-08-09 were exactly this. Mirrors
                    # snapshot.attach_macro_parameters.
                    sim_params = dict(instance.strategy_params or {})
                    if (
                        instance.strategy_key in SESSION_ANCHORED_STRATEGIES
                        or "anchor_start_min" in sim_params
                    ):
                        sim_params.setdefault(
                            "broker_utc_offset_min", BROKER_WINTER_OFFSET_MIN)
                        sim_params.setdefault("broker_dst_rule", BROKER_DST_RULE)
                    result = fn(data, **filter_params(fn, sim_params))
                    # Count WALK-TRADES, not raw flags: vectorbt takes an
                    # entry flag only when its single position is flat, so
                    # a run of consecutive flags is ONE trade. Counting raw
                    # flags made every extra flag in a run look like a
                    # "missed" live entry (wrb 2 flags -> 1 trade -> 1 live
                    # fill was reported missed=1). Ports with trailing_stop
                    # exits never flag an exit; for them each flag is
                    # counted only when the walk is flat AND at least one
                    # bar has passed since the last counted flag-run.
                    signals = []
                    le = result.get("long_entries")
                    se = result.get("short_entries")
                    lx = result.get("long_exits")
                    sx = result.get("short_exits")
                    index = data.index
                    flags = {
                        "long": (le.astype(bool) if le is not None else None),
                        "short": (se.astype(bool) if se is not None else None),
                    }
                    exits = {
                        "long": (lx.astype(bool) if lx is not None else None),
                        "short": (sx.astype(bool) if sx is not None else None),
                    }
                    trailing = bool(result.get("trailing_stop"))
                    position = 0
                    for i, ts in enumerate(index):
                        l_flag = bool(flags["long"].iloc[i]) if flags["long"] is not None else False
                        s_flag = bool(flags["short"].iloc[i]) if flags["short"] is not None else False
                        if position == 0:
                            direction = "buy" if l_flag else ("sell" if s_flag else None)
                            if direction is not None:
                                if to_epoch(ts) >= since.timestamp():
                                    signals.append((to_epoch(ts), direction))
                                position = 1 if direction == "buy" else -1
                        if position == 1:
                            if exits["long"] is not None and bool(exits["long"].iloc[i]):
                                position = 0
                            elif trailing and not l_flag:
                                # Trailing exits are invisible to flags: the
                                # walk frees up when the flag-run ends, so a
                                # LATER fresh run counts as a new trade.
                                position = 0
                        elif position == -1:
                            if exits["short"] is not None and bool(exits["short"].iloc[i]):
                                position = 0
                            elif trailing and not s_flag:
                                position = 0
                    # Exit design of this port, read off the replay result
                    # itself (no hardcoded lists): drives the exit-parity
                    # structure checks after the loop.
                    tp_series = result.get("take_profit")
                    exit_meta[str(instance.id)] = {
                        "key": f"{instance.strategy_key} {instance.symbol} "
                               f"{instance.timeframe}",
                        "trailing": bool(result.get("trailing_stop")),
                        "has_target": bool(
                            tp_series is not None
                            and (tp_series == tp_series).any()
                        ),
                        "session": (
                            instance.strategy_key in SESSION_ANCHORED_STRATEGIES
                            or "broker_dst_rule" in sim_params
                        ),
                    }
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
                # Only judge live entries the sim could possibly see: the
                # broker-bar cache can lag hours behind an ad-hoc run
                # (2026-08-20: an evening run produced 15 false "extra
                # live entry" alerts because the cache ended mid-morning
                # while the book traded all afternoon). Entries after the
                # data end are unverifiable, not wrong; a cache more than
                # a day stale is its own alert.
                data_end = to_epoch(data.index.max())
                verifiable = [
                    d
                    for d in live_entries
                    if datetime.fromisoformat(d["time"]).timestamp()
                    <= data_end + tf_seconds
                ]
                leg["unverifiable_live_entries"] = len(live_entries) - len(
                    verifiable
                )
                # Weekend-aware: on Sat/Sun/Mon-morning the newest bar is
                # legitimately Friday's (a D1 bar is >24h old by Saturday).
                stale_after = 86_400 if now.weekday() < 5 else 3 * 86_400
                if now.timestamp() - data_end > stale_after:
                    alerts.append(
                        f"deployment {pid} {instance.strategy_key} "
                        f"{instance.symbol}: broker-bar data ends "
                        f"{data.index.max()} — more than a day stale, live "
                        "entries cannot be verified"
                    )
                unmatched_live = list(verifiable)
                matched = 0
                # Strategies mark the entry on the bar where execution
                # happens, so a live fill prints seconds after that bar's
                # OPEN (the engine fires when the previous bar closes).
                missed_signal_times: list[dict] = []
                for bar_open, direction in sorted(signals):
                    hit = None
                    for deal in unmatched_live:
                        deal_epoch = datetime.fromisoformat(deal["time"]).timestamp()
                        if deal["side"] == direction and (
                            bar_open - MATCH_EARLY_SLACK
                            <= deal_epoch
                            <= bar_open + late_slack
                        ):
                            hit = deal
                            break
                    if hit is not None:
                        unmatched_live.remove(hit)
                        matched += 1
                    else:
                        # Actionable alert: say WHEN the sim wanted in, so
                        # the miss can be checked against the engine log.
                        missed_signal_times.append(
                            {
                                "bar_open": datetime.fromtimestamp(
                                    bar_open, tz=timezone.utc
                                ).isoformat(),
                                "side": direction,
                            }
                        )

                leg.update(
                    {
                        "simulated_signals": len(signals),
                        "live_entries": len(verifiable),
                        "matched": matched,
                        "missed_signals": len(signals) - matched,
                        "missed_signal_times": missed_signal_times,
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
                missed = len(signals) - matched
                if missed > 0:
                    alerts.append(
                        f"deployment {pid} {instance.strategy_key} "
                        f"{instance.symbol} {instance.timeframe}: "
                        f"{missed} backtest signal(s) with NO live entry "
                        f"({', '.join(m['bar_open'][:16] + ' ' + m['side'] for m in missed_signal_times)}) — "
                        "check engine logs for a suppression reason; a miss "
                        "with no reason is an executor bug"
                    )
                legs_out.append(leg)

            total_live = sum(leg.get("live_entries", 0) for leg in legs_out)
            total_matched = sum(leg.get("matched", 0) for leg in legs_out)
            exit_summary = run_exit_parity(
                pid=pid,
                client=client,
                deals=deals,
                exit_meta=exit_meta,
                alerts=alerts,
                now=now,
            )
            report["deployments"][str(pid)] = {
                "portfolio": portfolio.name,
                "legs": legs_out,
                "live_entries": total_live,
                "live_entries_matched": total_matched,
                "exit_parity": exit_summary,
            }

    report["ok"] = not alerts
    print(json.dumps(report, indent=1))
    sys.exit(0)


main()
