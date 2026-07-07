# SMA App Architecture

SMA App is the public marketing site and product delivery platform for
Systematic Mind Academy. Production runs as a Docker Compose stack on a Linux
server.

```text
Internet
↓ HTTPS :443
Caddy
↓ HTTP
Nginx
↓ FastCGI
PHP-FPM (Laravel)
↓
MySQL
```

Background workers:

- `queue` — Laravel queue worker
- `scheduler` — Laravel task scheduler

## Production Domains

- Primary site: `https://systematicmindacademy.com`
- Redirect: `https://www.systematicmindacademy.com` → apex domain

## Runtime Repository

Production application code lives in the `sma_app` repository on the server.
Infrastructure automation does not install the `sma-infrastructure` repository
on the app server.

Typical server path:

```text
/opt/sma/sma_app
```

Adjust `sma_app_repo_path` in the inventory or playbook if your server uses a
different path.

## Secrets Boundary

Production secrets stay on the server in `.env.production`:

- Laravel `APP_KEY`
- MySQL credentials
- Admin bootstrap credentials
- Resend API key
- Payment provider secrets

Ansible deployment automation validates that `.env.production` exists, but does
not manage or overwrite secret values.

## Deployment Model

Deployment is workstation-driven from `sma-infrastructure`:

```text
MacBook workstation
↓ Ansible over SSH
Linux app server
↓ git pull + make prod-deploy
Docker Compose production stack
```

The deployment playbook:

1. Verifies the repository and `.env.production` exist.
2. Refuses to deploy over a dirty Git working tree.
3. Fetches and checks out the selected branch.
4. Runs `make prod-deploy` in the app repository.
5. Validates public HTTPS health.
6. Prints a deployment summary.

See [Linux server operations](linux-server.md) for first-time server setup.
