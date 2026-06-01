# SMA Infrastructure

Infrastructure-as-Code, provisioning automation, and operational documentation
for Systematic Mind Academy services.

This repository is the source of truth for provisioning and operating SMA
servers. Automation is executed from an administrator's workstation. Target
servers should receive only the configuration and runtime artifacts required to
perform their role; this repository should not be installed on them.

## Repository Structure

```text
sma-infrastructure/
├── README.md
├── docs/
│   └── execution-node/
│       ├── architecture.md
│       ├── windows-vps.md
│       └── findings.md
├── ansible/
│   ├── inventories/
│   ├── playbooks/
│   └── roles/
└── scripts/
```

- `docs/` records validated architecture decisions, server requirements, and
  operational findings.
- `ansible/inventories/` will define managed environments and hosts.
- `ansible/playbooks/` will contain workstation-driven provisioning workflows.
- `ansible/roles/` will contain reusable server configuration units.
- `scripts/` will contain focused administrator utilities when a playbook is
  not the appropriate tool.

## Guiding Principles

1. Provision infrastructure from a controlled administrator workstation.
2. Keep infrastructure code out of target servers.
3. Document validated behavior before automating it.
4. Prefer small, repeatable provisioning steps over manual server drift.
5. Treat secrets as external inputs. Do not commit credentials, API keys, or
   broker account information.
6. Keep runtime choices aligned with platform constraints. SMA Execution Node
   uses Windows Native Runtime in production because MetaTrader 5 is a native,
   stateful Windows terminal.
7. Preserve Docker where it is useful for local development, CI, and testing
   without forcing it into MT5 production nodes.

## Current Infrastructure Status

Execution Node #1 has been provisioned manually on a Windows Server 2025 VPS.
The native runtime has been validated end to end:

```text
SMA Portfolio Lab
↓ HTTP
SMA Execution Node API
↓ local IPC
MetaTrader5 Python package
↓
MetaTrader 5 Terminal
↓
Broker
```

The API can retrieve account information, broker symbols, and historical
candles. Reboot testing confirmed that broker login state persists after the
terminal is reopened. Automatic recovery after reboot has not been configured
yet: the MT5 terminal and Execution Node API are still started manually.

See:

- [Execution Node architecture](docs/execution-node/architecture.md)
- [Windows VPS operations](docs/execution-node/windows-vps.md)
- [Validated findings](docs/execution-node/findings.md)

## Roadmap

1. Record the manually validated Windows VPS provisioning process.
2. Define an Ansible inventory for Execution Node #1.
3. Automate Windows prerequisites, Python setup, and runtime configuration from
   the administrator workstation.
4. Validate unattended reboot recovery for MT5 and the Execution Node API.
5. Add monitoring, log collection, backups, and network hardening.
6. Add Linux provisioning for SMA Portfolio Lab.
7. Introduce centralized secrets management before scaling beyond internal
   infrastructure.

