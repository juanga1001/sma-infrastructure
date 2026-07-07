# Execution Node Playbooks

These playbooks manage the validated Windows Native Runtime for SMA Execution
Node. They do not use Docker, Gunicorn, or Linux service management. Runtime
recovery is handled by Windows Scheduled Tasks:

```text
SMA-MT5-Terminal
SMA-Execution-Node
```

## Validate Execution Node

Use the read-only validation playbook to confirm that a Windows Execution Node
is operational without opening an RDP session:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  ansible/playbooks/validate-execution-node.yml
```

The playbook verifies:

- WinRM connectivity
- Windows Firewall inbound rule for TCP port `8000`
- `SMA-MT5-Terminal` Scheduled Task
- `SMA-Execution-Node` Scheduled Task
- `terminal64.exe` process
- TCP port `8000`
- local Execution Node `/health` endpoint
- `status=ok`
- `mt5_connected=true`

The ignored local `vault/execution-node.yml` file must include:

```yaml
ansible_user: Administrator
ansible_password: your-local-password
execution_node_api_key: your-local-api-key
```

Do not commit local credentials or API keys.

For deployment, the VPS must be able to fetch from the `sma-execution-node`
GitHub repository without an interactive prompt. The current production path
uses SSH repository access configured directly on the Execution Node host. The
deployment playbook validates this by running a non-interactive Git remote
check before fetching or pulling.

## Configure Execution Node Network

Use the network configuration playbook to make the Execution Node API reachable
from Portfolio Lab and administrator workstations:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  ansible/playbooks/configure-execution-node-network.yml
```

The playbook ensures this Windows Firewall rule exists:

```text
Display name: SMA Execution Node API 8000
Direction: Inbound
Protocol: TCP
Local port: 8000
Action: Allow
Profile: Any
```

The rule is required because the Execution Node can be healthy locally while
still being unreachable from Portfolio Lab if inbound TCP `8000` is blocked.

## Configure MT5 MaxBars

Use the MT5 chart history-depth playbook to configure the terminal for deeper
intraday research and restart the Windows Native Runtime tasks:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  ansible/playbooks/configure-mt5-max-bars.yml
```

By default, the playbook sets:

```text
MaxBars=1000000
```

This is intended to support roughly five years of M5 research history with
headroom. The value can be overridden when needed:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  -e mt5_max_bars=1500000 \
  ansible/playbooks/configure-mt5-max-bars.yml
```

The playbook:

1. Writes `C:\SMA\mt5\sma-terminal.ini`.
2. Sets `[Charts] MaxBars` and `[Experts] AllowLiveTrading=1` (required for Python order APIs).
3. Updates `SMA-MT5-Terminal` to launch MT5 with `/config:...`.
4. Stops the Execution Node API task.
5. Stops and restarts MetaTrader 5.
6. Starts the Execution Node API task.
7. Waits for `/health` to report `status=ok`, `mt5_connected=true`, and the
   requested `mt5_max_bars`.

This playbook intentionally restarts MT5 because MetaTrader applies `MaxBars`
only after a terminal restart.

## Configure MT5 Algo Trading

Use this playbook after provisioning a new VPS or when `/accounts/test-trade`
returns *“MetaTrader auto-trading is disabled in the terminal.”*

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  ansible/playbooks/configure-mt5-algo-trading.yml
```

The playbook:

1. Writes `C:\SMA\mt5\sma-terminal.ini` with `[Experts] Enabled=1` and
   `AllowLiveTrading=1`.
2. Restarts MetaTrader 5 and the Execution Node API.
3. Toggles the MT5 Algo Trading toolbar state when a window handle is available.
4. Verifies `terminal.trade_allowed` through the MetaTrader5 Python package.

## Fix MT5 Algo Trading (recovery)

Use this lighter playbook when algo trading was disabled manually or after a
terminal reset. It patches MetaTrader `common.ini` under AppData, restarts MT5
and the API, and verifies algo trading is enabled:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  ansible/playbooks/fix-mt5-algo-trading.yml
```

Run this before relying on Portfolio Lab **Test Trade** or any future live
order execution.

## Configure Execution Node Watchdog

Install the local watchdog that restarts the Execution Node API and MT5 when
health checks fail while the VPS is running:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  ansible/playbooks/configure-execution-node-watchdog.yml
```

The watchdog:

- Runs every **2 minutes** as `SMA-Execution-Node-Watchdog`
- Checks `http://localhost:8000/healthcheck`
- Restarts `SMA-Execution-Node` when the API is down
- Restarts `SMA-MT5-Terminal` when `terminal64.exe` is not running
- Logs actions to `C:\SMA\logs\execution-node-watchdog.log`
- Runs as the same Windows user as the runtime tasks (typically `Administrator`)

If the watchdog task is missing, inspect `C:\SMA\logs\execution-node-watchdog.log` and re-run
`configure-execution-node-watchdog.yml`. Older builds used an invalid infinite repetition
duration that Windows Task Scheduler rejects silently.

`deploy-execution-node.yml` installs or refreshes this watchdog automatically.

## Configure Execution Node Environment

Use this playbook to idempotently insert or update non-secret values in
`C:\SMA\sma-execution-node\.env` without opening an RDP session:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  ansible/playbooks/configure-execution-node-env.yml
```

By default it ensures:

```text
MT5_PATH=C:\Program Files\MetaTrader 5\terminal64.exe
MT5_TERMINAL_TEMPLATE_DIR=C:\SMA\MT5\_template
MT5_TERMINAL_CONFIG_PATH=C:\SMA\mt5\sma-terminal.ini
ACCOUNT_CONNECTION_TEST_TIMEOUT_SECONDS=300
```

Override a path when needed:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  -e execution_node_mt5_path='D:\MetaTrader 5\terminal64.exe' \
  ansible/playbooks/configure-execution-node-env.yml
```

The helper script upserts each key: existing lines are updated, missing keys are
appended. Broker credentials and API keys should remain in the VPS `.env` or
local vault files; only infrastructure defaults belong in this playbook.

`deploy-execution-node.yml` runs this playbook automatically after `git pull`
and before restarting the API.

## Deploy Execution Node

Use the deployment playbook to update the Windows VPS from GitHub, restart the
Execution Node API Scheduled Task, and run the validation playbook:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  ansible/playbooks/deploy-execution-node.yml
```

By default, the playbook deploys `main`. To deploy a specific branch:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  -e execution_node_git_branch=feature/deployment-runtime-state \
  ansible/playbooks/deploy-execution-node.yml
```

The playbook performs the deployment in this order:

1. Ensure the Windows Firewall allows inbound TCP `8000`.
2. Verify `C:\SMA\sma-execution-node` exists.
3. Verify the Git working tree is clean.
4. Verify the Git remote can authenticate non-interactively.
5. Fetch remote Git state.
6. Checkout the selected branch from `origin`.
7. Pull the latest selected branch.
8. Ensure managed `.env` values such as `MT5_PATH`.
9. Capture commit metadata.
10. Restart only the `SMA-Execution-Node` Scheduled Task.
11. Wait for `http://localhost:8000/health` to return `status=ok`.
12. Reuse `validate-execution-node.yml`.
13. Install or refresh the watchdog.
14. Print the deployment summary.

The playbook intentionally does not stop or restart `SMA-MT5-Terminal`. MT5 must
remain running so the Python API can reconnect through the existing terminal
session.

Expected summary:

```text
Deployment Successful
Branch: feature/deployment-runtime-state
Commit: 5870b92...
Message: feat: add deployment runtime state management
Health: OK
Result: OK
```

The deployment fails before making changes if the remote working tree contains
local modifications. This protects manual hotfixes, diagnostics, and any
uncommitted operator state from being overwritten by automation.

### Typical release workflow

1. Develop and test locally in `sma-execution-node` (`make test`).
2. Commit and push to GitHub (`git push origin main`).
3. Run `deploy-execution-node.yml` from this repository on the administrator
   workstation.
4. Validate from Portfolio Lab: Test Connection → Test Trade → portfolio deploy
   test (see Portfolio Lab `docs/platform-and-operations.md`).

If test trade fails with algo trading disabled, run `fix-mt5-algo-trading.yml`
before redeploying application code.
