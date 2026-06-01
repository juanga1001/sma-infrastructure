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

## Current Manual Startup Process

After a VPS reboot:

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

- MT5 does not start automatically.
- The Execution Node API does not start automatically.
- MT5 preserves the configured broker login.
- The Execution Node API reconnects successfully after MT5 and Uvicorn are
  started manually.

## Open Questions

The next operational design step is unattended reboot recovery. The leading
candidate is:

```text
Dedicated non-admin execution user
↓ automatic Windows login
Task Scheduler
├── start MetaTrader 5 terminal
└── start Execution Node API after MT5 is ready
```

Before implementation, validate:

- the dedicated Windows execution account and permission model
- whether automatic login is acceptable for the VPS threat model
- the exact MT5 executable path and terminal data directory strategy
- Task Scheduler ordering, retry behavior, and log handling
- API network exposure, firewall allowlist, and private network design
- HTTPS termination strategy
- monitoring and alerting when `/health` becomes degraded
- PostgreSQL topology and whether the Execution Node requires persistent
  database storage during its current market-data-only phase

NSSM and WinSW service wrappers remain deferred until their Session 0 behavior
is explicitly validated against the MT5 terminal IPC requirement.

