# Ansible Workstation Setup

## Purpose

SMA infrastructure is managed from an administrator workstation using Ansible.
The initial control machine is the developer MacBook. Target servers receive
only the configuration and runtime artifacts required to perform their role.

```text
MacBook workstation
↓ Ansible
WinRM HTTPS
↓
Windows Execution Node VPS
```

## Why Ansible Runs from the Workstation

The workstation is the control plane for infrastructure automation. This keeps
provisioning logic centralized, version-controlled, and reviewable while
avoiding manual server drift.

Running Ansible from the workstation provides:

- one source of truth for server configuration
- repeatable provisioning across execution nodes
- a clear audit trail through Git history
- separation between infrastructure automation and application runtimes
- a foundation for managing Windows Execution Nodes and future Linux services

## Why Infrastructure Code Is Not Installed on Servers

Target servers should not clone or execute this repository directly. A server
should contain only the packages, configuration, and application artifacts
needed for its assigned runtime role.

This reduces:

- unnecessary access to infrastructure source code
- secrets exposure risk
- configuration drift caused by manual server-side edits
- coupling between provisioning automation and runtime processes

Infrastructure changes should be applied from the workstation through Ansible.

## Why WinRM HTTPS Is Used

Windows Remote Management (WinRM) is the remote-management transport used by
Ansible for Windows hosts. Production connectivity should use WinRM over HTTPS
on TCP port `5986`.

HTTPS provides transport encryption for remote administration traffic. Initial
connectivity may use certificate-validation bypass for a controlled
environment with a self-signed certificate:

```yaml
ansible_winrm_server_cert_validation: ignore
```

This should be revisited when certificate management is formalized. Network
access to port `5986` must remain restricted to trusted administration sources.

## Local Setup

Run the following commands from the `sma-infrastructure` repository on the
MacBook.

### Create a Python Virtual Environment

```bash
python3 -m venv .venv
```

### Activate the Virtual Environment

```bash
source .venv/bin/activate
```

### Install Workstation Dependencies

```bash
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

## Verify Installation

Confirm that Ansible is installed:

```bash
ansible --version
```

Confirm that the WinRM Python client is installed:

```bash
python -c "import winrm; print(winrm.__version__)"
```

Expected result:

- `ansible --version` prints the installed Ansible version and Python runtime.
- The Python command prints the installed `pywinrm` version.

## Inventory Preparation

The documented production inventory template is:

```text
ansible/inventories/production/hosts.yml
```

Before testing connectivity, replace its placeholders with the Windows VPS host
address and the dedicated Windows administration user. Do not commit real
credentials.

The inventory intentionally does not store a password. Supply credentials
outside Git when running Ansible. A secrets-management workflow will be added
before infrastructure automation expands.

## Next Milestone

The next milestone is validating WinRM HTTPS connectivity from the MacBook to
Execution Node #1. Do not add provisioning playbooks until the remote-management
transport is proven reliable.
