# Execution Node #1: Windows VPS

## Purpose

Execution Node #1 is the first broker-connected SMA runtime. It validates the
Windows Native Runtime architecture and currently serves MT5 historical market
data to SMA Portfolio Lab.

## Server Profile

| Item | Value |
| --- | --- |
| Provider | Contabo |
| Operating system | Windows Server 2025 |
| CPU | 4 vCPU |
| Memory | 8 GB RAM |
| Runtime role | SMA Execution Node #1 |

## Installed Components

The following components have been installed and validated:

- Python 3.11
- Poetry
- SMA Execution Node repository
- Official `MetaTrader5` Python package
- MetaTrader 5 terminal
- Axi demo broker account
- Native FastAPI application served by Uvicorn

## Manual Startup Fallback

If automatic recovery fails after a VPS reboot:

1. Sign in to Windows Server.
2. Launch the MetaTrader 5 terminal.
3. Confirm that the broker account reconnects.
4. Open PowerShell in the SMA Execution Node repository.
5. Start the API:

   ```powershell
   py -3.11 -m poetry run uvicorn src.main:app --host 0.0.0.0 --port 8000
   ```

6. Verify MT5 connectivity:

   ```powershell
   Invoke-RestMethod `
     -Headers @{ "X-API-Key" = "<execution-node-api-key>" } `
     -Uri "http://localhost:8000/health"
   ```

7. Verify historical data:

   ```powershell
   Invoke-RestMethod `
     -Headers @{ "X-API-Key" = "<execution-node-api-key>" } `
     -Uri "http://localhost:8000/rates?symbol=XAUUSD&timeframe=M5&start=2026-01-01&end=2026-01-31"
   ```

Credentials and API keys must remain outside this repository.

## Validated API Endpoints

```text
GET /healthcheck
GET /health
GET /account
GET /symbols
GET /rates
```

## Current Reboot Behavior

Reboot testing confirmed:

- Scheduled Tasks start MT5 automatically inside the interactive Windows
  runtime session.
- Scheduled Tasks start the Execution Node API automatically after MT5.
- MT5 preserves the configured broker login.

Algo trading settings are persisted in `C:\SMA\mt5\sma-terminal.ini` and
MetaTrader `common.ini`. If test trades fail after reboot, run the
`fix-mt5-algo-trading.yml` Ansible playbook (see
`ansible/playbooks/README.md` in sma-infrastructure).
- The Execution Node API reconnects successfully to MT5.
- `GET /health` returns `mt5_connected=true` after reboot recovery.

## Open Questions

The native runtime and unattended reboot-recovery flow have been validated.
Remaining operational questions include:

- WinRM HTTPS connectivity from the administrator workstation
- API network exposure, firewall allowlist, and private network design
- HTTPS termination strategy
- monitoring and alerting when `/health` becomes degraded
- PostgreSQL topology and whether the Execution Node requires persistent
  database storage during its current market-data-only phase

NSSM and WinSW service wrappers remain deferred until their Session 0 behavior
is explicitly validated against the MT5 terminal IPC requirement. The current
interactive-session Scheduled Task model remains the supported runtime.
