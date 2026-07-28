#!/usr/bin/env bash
# SMA deploy script (C9). Replaces the ad-hoc tarball flow whose additive
# copies never deleted files — a stale turtle_soup_scalper import nearly
# crashed the engine on 2026-07-18. Every target does a FULL clean replace
# of the code tree followed by a restart.
#
# Usage (from the workstation with the repos + ssh key):
#   ./deploy.sh backend    # portfolio-lab backend app/ + tests/ -> container, restart
#   ./deploy.sh engine     # execution-node src/ + tests/ -> sma-engine, restart
#   ./deploy.sh frontend   # rsync --delete frontend/src -> droplet, image rebuild
#   ./deploy.sh all
set -euo pipefail

HOST="root@167.71.162.75"
KEY="$HOME/.ssh/id_ed25519_github"
LAB="$(cd "$(dirname "$0")/../../sma-portfolio-lab" && pwd)"
ENGINE="$(cd "$(dirname "$0")/../../sma-execution-node" && pwd)"
SSH=(ssh -i "$KEY" "$HOST")

replace_tree() { # $1 container  $2 local_dir  $3 remote_parent  $4 tree_name
  local container="$1" local_dir="$2" parent="$3" tree="$4"
  local tarball
  tarball="$(mktemp /tmp/deploy-XXXX.tgz)"
  # COPYFILE_DISABLE + the ._* exclusion keep macOS AppleDouble resource
  # forks out of the tree. One of them (._b7f1a2c3d4e5_*.py) landed in
  # alembic/versions and broke every migration command with "source code
  # string cannot contain null bytes" until 2026-07-27.
  COPYFILE_DISABLE=1 tar -C "$local_dir" --exclude='._*' --exclude='.DS_Store' \
    --exclude='__pycache__' -czf "$tarball" "$tree"
  scp -q -i "$KEY" "$tarball" "$HOST:/tmp/deploy-tree.tgz"
  rm -f "$tarball"
  "${SSH[@]}" "docker cp /tmp/deploy-tree.tgz $container:/tmp/deploy-tree.tgz && \
    docker exec $container bash -c '\
      set -e; rm -rf /tmp/deploy-new; mkdir /tmp/deploy-new; \
      tar -C /tmp/deploy-new -xzf /tmp/deploy-tree.tgz; \
      rm -rf $parent/$tree; mv /tmp/deploy-new/$tree $parent/$tree; \
      rm -rf /tmp/deploy-new /tmp/deploy-tree.tgz'"
}

deploy_backend() {
  echo "== backend: clean replace app/ + tests/ + scripts/, restart"
  replace_tree portfolio-lab-backend-1 "$LAB/backend" /app/backend app
  replace_tree portfolio-lab-backend-1 "$LAB/backend" /app/backend tests
  # scripts/ holds the operational tooling (publish, redeploy, composition
  # sync, macro refresh); leaving it out stranded new scripts on the
  # workstation and made every run a manual docker cp.
  replace_tree portfolio-lab-backend-1 "$LAB/backend" /app/backend scripts
  "${SSH[@]}" "docker restart portfolio-lab-backend-1 >/dev/null"
  "${SSH[@]}" "sleep 5; docker ps --filter name=portfolio-lab-backend-1 --format 'backend {{.Status}}'"
}

deploy_engine() {
  echo "== engine: clean replace src/ + tests/, restart"
  replace_tree sma-engine "$ENGINE" /app src
  replace_tree sma-engine "$ENGINE" /app tests
  "${SSH[@]}" "docker restart sma-engine >/dev/null"
  "${SSH[@]}" "sleep 8; docker ps --filter name=sma-engine --format 'engine {{.Status}}'"
}

deploy_frontend() {
  echo "== frontend: rsync --delete src/, image rebuild"
  rsync -az --delete -e "ssh -i $KEY" "$LAB/frontend/src/" "$HOST:/opt/sma/portfolio-lab/frontend/src/"
  "${SSH[@]}" "cd /opt/sma/portfolio-lab && \
    docker compose -f compose.server.yml --env-file .env.server build frontend 2>&1 | tail -1 && \
    docker compose -f compose.server.yml --env-file .env.server up -d frontend 2>&1 | tail -1"
}

case "${1:-}" in
  backend)  deploy_backend ;;
  engine)   deploy_engine ;;
  frontend) deploy_frontend ;;
  all)      deploy_backend; deploy_engine; deploy_frontend ;;
  *) echo "usage: $0 backend|engine|frontend|all" >&2; exit 1 ;;
esac
echo "== done"
