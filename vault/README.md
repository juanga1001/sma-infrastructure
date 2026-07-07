# Local Workstation Secrets

This directory is reserved for local workstation-managed secrets used by
Ansible. Secret files must never be committed to Git.

The tracked files in this directory are documentation and templates only:

```text
vault/
├── .gitkeep
├── README.md
├── execution-node.example.yml
└── sma-app.example.yml
```

Create a local credential file from the template:

```bash
cp vault/execution-node.example.yml vault/execution-node.yml
cp vault/sma-app.example.yml vault/sma-app.yml
```

Edit `vault/execution-node.yml` locally:

```yaml
ansible_user: Administrator
ansible_password: your-local-password
execution_node_api_key: your-local-api-key
```

Edit `vault/sma-app.yml` locally:

```yaml
ansible_user: deploy
ansible_ssh_private_key_file: ~/.ssh/sma_app_deploy
```

Use the local file as Ansible extra variables:

```bash
ansible execution_nodes \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  -m win_ping

ansible sma_app_servers \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/sma-app.yml \
  -m ping
```

The `.gitignore` rules prevent `vault/execution-node.yml` and other local vault
files from being committed. Confirm this before adding any new secret-file
pattern:

```bash
git check-ignore -v vault/execution-node.yml
```

## Future Migration

Plain local secret files are an intentionally small first step for validating
workstation-driven management. Migrate these credentials to `ansible-vault` or
another approved secrets-management system before infrastructure automation
expands.
