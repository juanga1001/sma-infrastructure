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
├── requirements.txt
├── vault/
│   ├── README.md
│   └── execution-node.example.yml
├── docs/
│   ├── ansible-workstation.md
│   └── execution-node/
│       ├── architecture.md
│       ├── windows-vps.md
│       └── findings.md
├── ansible/
│   ├── inventories/
│   │   └── production/
│   │       └── hosts.yml
│   ├── playbooks/
│   │   └── validate-execution-node.yml
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
terminal is reopened. Automatic recovery after reboot has also been validated:
scheduled tasks start the MT5 terminal and Execution Node API inside the
interactive Windows runtime session.

See:

- [Execution Node architecture](docs/execution-node/architecture.md)
- [Windows VPS operations](docs/execution-node/windows-vps.md)
- [Validated findings](docs/execution-node/findings.md)

## Ansible Workstation

Infrastructure management is executed from an administrator workstation. The
initial control machine is the developer MacBook:

```text
MacBook
↓ Ansible
WinRM HTTPS
↓
Windows VPS
```

Create and activate a local Python environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

See [Ansible workstation setup](docs/ansible-workstation.md) for the full
workflow and the rationale behind workstation-driven provisioning.

Authenticated WinRM HTTPS connectivity from the MacBook to Execution Node #1
has been validated with `win_ping`.

## Local Secrets Management

Local Ansible credentials belong in the ignored `vault/` directory. Create a
local credential file from the tracked template:

```bash
cp vault/execution-node.example.yml vault/execution-node.yml
```

Populate `vault/execution-node.yml` with the workstation-managed Windows
credentials. Do not commit that file.

Use the local credentials as Ansible extra variables:

```bash
ansible execution_nodes \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  -m win_ping
```

See [Local workstation secrets](vault/README.md) for the current local workflow.
Migration to `ansible-vault` is expected before infrastructure automation
expands.

## Validation Playbook

Validate Execution Node health from the administrator workstation:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  ansible/playbooks/validate-execution-node.yml
```

The read-only playbook verifies WinRM, runtime Scheduled Tasks, the MT5 process,
port `8000`, the local `/health` endpoint, and MT5 connectivity. See
[Execution Node playbooks](ansible/playbooks/README.md) for the full validation
contract.

## Roadmap

1. Validate Execution Node health from the administrator workstation.
2. Automate Windows prerequisites, Python setup, and runtime configuration from
   the administrator workstation.
3. Add monitoring, log collection, backups, and network hardening.
4. Add Linux provisioning for SMA Portfolio Lab.
5. Introduce centralized secrets management before scaling beyond internal
   infrastructure.
