# Execution Node Validated Findings

This document records observed behavior from the first Windows VPS deployment.
These are validated findings, not assumptions.

## Native Windows Runtime

- SMA Execution Node runs successfully as a native Python application on
  Windows Server 2025.
- Python 3.11 and Poetry work correctly for the application runtime.
- The official `MetaTrader5` Python package installs and communicates correctly
  with the local MetaTrader 5 terminal.
- Docker is not required for MT5-connected production Execution Nodes.
- Docker remains useful for local development, CI, and mocked application
  testing.

## Broker and Market Data Connectivity

- The MetaTrader 5 terminal connects successfully to the configured Axi demo
  broker account.
- Python can call `mt5.initialize()` successfully.
- Python can retrieve broker account information.
- Python can retrieve historical broker candles through
  `mt5.copy_rates_range(...)`.
- The Execution Node API successfully exposes:

  ```text
  GET /healthcheck
  GET /health
  GET /account
  GET /symbols
  GET /rates
  ```

## Reboot Validation

A Windows VPS reboot test was completed.

Observed immediately after reboot:

- The MetaTrader 5 terminal was not running.
- The SMA Execution Node API was not running.

Observed after manually launching MT5:

- The broker account remained connected.
- No manual broker re-login was required.
- Historical market data remained available.

Observed after manually starting the Execution Node API:

- The API reconnected successfully to the local MT5 terminal.
- `GET /health` returned:

  ```json
  {
    "status": "ok",
    "mt5_connected": true
  }
  ```

## Current Operational Gap

MT5 connectivity is proven. The remaining gap is unattended startup after a
Windows reboot.

The next investigation should validate an interactive-session startup model
using a dedicated execution user, automatic Windows login, and Task Scheduler.
Windows service wrappers should remain deferred until Session 0 behavior is
explicitly proven compatible with the MT5 terminal.

