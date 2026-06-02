# SMA Execution Node Architecture

## Purpose

SMA Execution Node is the broker-adjacent runtime plane for Systematic Mind
Academy. Its first responsibility is exposing reliable broker historical data
to SMA Portfolio Lab. Future responsibilities may include market polling and
trade execution, but those are outside the current scope.

## High-Level Architecture

```text
SMA Portfolio Lab
↓ authenticated HTTP
SMA Execution Node API
↓ adapter boundary
MetaTrader5 Python package
↓ local inter-process communication
MetaTrader 5 Terminal
↓ broker session
Broker
```

## Component Responsibilities

### SMA Portfolio Lab

SMA Portfolio Lab is the control plane. It owns portfolio research,
backtesting, strategy management, and the user-facing application. It requests
historical broker data from an Execution Node over HTTP.

### SMA Execution Node API

The Execution Node API is a native FastAPI application running close to the
broker runtime. It exposes authenticated health, account, symbol, and historical
rates endpoints. Broker-specific behavior stays behind an adapter boundary.

### MetaTrader5 Python Package

The official `MetaTrader5` Python package is the local integration bridge. It is
not a standalone remote broker SDK. It communicates with a locally running MT5
terminal through inter-process communication.

### MetaTrader 5 Terminal

The MT5 terminal is a stateful Windows desktop runtime. It owns the broker
session, symbol catalog, and historical market data access. The connected
broker account is configured inside the terminal.

### Broker

The broker provides the account session, available market symbols, and
historical candles consumed by Portfolio Lab research workflows.

## Runtime Strategy

### Production

MT5-connected Execution Nodes use Windows Native Runtime:

```text
Windows Server
├── MetaTrader 5 Terminal
└── Native Python FastAPI Execution Node
```

This is the supported production model because the official `MetaTrader5`
package requires a local Windows terminal. Linux containers do not replace that
runtime relationship.

### Development and CI

Docker remains useful for:

- local FastAPI development
- dependency isolation
- linting
- mocked unit tests
- CI validation

Docker is intentionally not the primary production runtime for MT5-connected
Execution Nodes.

## Current Operational Boundary

The first deployed node is focused on historical market data:

```text
GET /healthcheck
GET /health
GET /account
GET /symbols
GET /rates
```

Trade execution, portfolio orchestration, and multi-account operation will be
introduced only after the Windows-native runtime and workstation-driven
infrastructure management are operationally stable.
