# Local Workstation Secrets

This directory is reserved for local workstation-managed secrets used by
Ansible. Secret files must never be committed to Git.

The tracked files in this directory are documentation and templates only:

```text
vault/
├── .gitkeep
├── README.md
└── execution-node.example.yml
```

Create a local credential file from the template:

```bash
cp vault/execution-node.example.yml vault/execution-node.yml
```

Edit `vault/execution-node.yml` locally:

```yaml
ansible_user: Administrator
ansible_password: your-local-password
```

Use the local file as Ansible extra variables:

```bash
ansible execution_nodes \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/execution-node.yml \
  -m win_ping
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
