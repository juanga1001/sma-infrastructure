# Execution Node Playbooks

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
