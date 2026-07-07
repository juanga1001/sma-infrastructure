# SMA App Linux Server Operations

## Purpose

This document describes what must exist on the SMA App production server before
workstation-driven Ansible deployment can run.

## Server Requirements

The production host must provide:

- Linux server with public access to ports `80` and `443`
- Docker Engine
- Docker Compose plugin
- Git
- DNS for `systematicmindacademy.com` and `www.systematicmindacademy.com`
- SSH access for an automation user from the administrator workstation

The server does not need bare-metal PHP, MySQL, Nginx, or Node installed outside
Docker. Those run inside the production Compose stack defined in `sma_app`.

## First-Time Server Setup

Run these steps once on the server before using Ansible deploy automation.

### 1. Create the deployment user

Create a dedicated Linux user for automation, for example `deploy`:

```bash
sudo adduser deploy
sudo usermod -aG docker deploy
```

The user must be able to run `docker` and `docker compose` without `sudo`.

### 2. Authorize workstation SSH access

From your MacBook, create or reuse an SSH key:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/sma_app_deploy -C "sma-app-deploy"
```

Install the public key on the server:

```bash
ssh-copy-id -i ~/.ssh/sma_app_deploy.pub deploy@YOUR_SERVER_IP
```

Verify login:

```bash
ssh -i ~/.ssh/sma_app_deploy deploy@YOUR_SERVER_IP
```

### 3. Clone the application repository

On the server:

```bash
sudo mkdir -p /opt/sma
sudo chown deploy:deploy /opt/sma
git clone git@github.com:YOUR_ORG/sma_app.git /opt/sma/sma_app
```

The server must be able to fetch from GitHub without an interactive prompt.
Configure a deploy key or another non-interactive Git credential on the server.

### 4. Create production environment file

On the server, create:

```text
/opt/sma/sma_app/.env.production
```

Use the production values documented in the `sma_app` repository README.
At minimum include:

- `APP_KEY`
- `APP_URL=https://systematicmindacademy.com`
- MySQL credentials
- Admin bootstrap credentials
- Resend mail settings

Do not commit this file to Git.

### 5. Run the first manual deploy

On the server:

```bash
cd /opt/sma/sma_app
make prod-deploy
```

Confirm the site is reachable at `https://systematicmindacademy.com`.

After this one-time bootstrap, routine releases should be run from the
administrator workstation with Ansible.

## Workstation Connection Requirements

From `sma-infrastructure`, configure two local files.

### Inventory

Edit:

```text
ansible/inventories/production/hosts.yml
```

Set the real server IP or hostname for `sma-app-01.ansible_host`.

If the repository path differs from `/opt/sma/sma_app`, override
`sma_app_repo_path` in inventory host vars.

### Local vault file

Create the ignored credential file:

```bash
cp vault/sma-app.example.yml vault/sma-app.yml
```

Populate it with the SSH user and private key path:

```yaml
ansible_user: deploy
ansible_ssh_private_key_file: ~/.ssh/sma_app_deploy
```

Use an absolute path for `ansible_ssh_private_key_file` if needed.

### Connectivity test

```bash
ansible sma_app_servers \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/sma-app.yml \
  -m ping
```

Expected result:

```text
sma-app-01 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

## Routine Deploy Workflow

1. Develop and test locally in `sma_app`.
2. Commit and push to GitHub.
3. From `sma-infrastructure`, run `deploy-sma-app.yml`.
4. Validate the public site and checkout buttons.

Deploy command:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/sma-app.yml \
  ansible/playbooks/deploy-sma-app.yml
```

Deploy a specific branch:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/sma-app.yml \
  -e sma_app_git_branch=feature/my-branch \
  ansible/playbooks/deploy-sma-app.yml
```

Read-only validation:

```bash
ansible-playbook \
  -i ansible/inventories/production/hosts.yml \
  -e @vault/sma-app.yml \
  ansible/playbooks/validate-sma-app.yml
```

## Operational Notes

- `make prod-deploy` runs database seeders on every deploy. Review seeder
  behavior before relying on deploy automation for routine releases.
- The deployment playbook refuses to run when the server working tree has local
  modifications.
- Keep `.env.production` server-side only. Do not store production secrets in
  `sma-infrastructure`.
