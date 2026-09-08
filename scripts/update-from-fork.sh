#!/usr/bin/env bash
# Update a community-scripts Homelable LXC from your own fork's branch instead
# of the upstream GitHub release.
#
# Mirrors the helper-script's update_script(): stop the service, back up the
# files the tarball does not carry (.env, data), deploy the source, rebuild the
# Python venv and the frontend, restart.
#
# Usage (inside the CT, as root):
#   bash /opt/homelable/scripts/update-from-fork.sh
#
# Overridable:
#   REPO=luu0124/homelable  BRANCH=main  APP_DIR=/opt/homelable  SERVICE=homelable
set -euo pipefail

REPO="${REPO:-luu0124/homelable}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/homelable}"
SERVICE="${SERVICE:-homelable}"
MCP_SERVICE="${MCP_SERVICE:-homelable-mcp}"
BACKUP_DIR="/root/homelable-backup-$(date +%Y%m%d-%H%M%S)"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Run as root."
[[ -d "$APP_DIR/backend" ]] || fail "$APP_DIR/backend not found — is this the Homelable CT?"
for bin in curl tar npm; do
  command -v "$bin" >/dev/null || fail "missing required command: $bin"
done

# The nmap check method shells out to the nmap binary. The helper-script
# installs it for the scanner, but a stripped CT may not have it.
if ! command -v nmap >/dev/null; then
  log "nmap not found — installing"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nmap
fi

# This script ships inside the tree it replaces, so the deploy step would
# overwrite the very file bash is still reading — bash reads a script by byte
# offset and would resume in the middle of the new bytes. Re-exec from a copy
# outside $APP_DIR before touching anything.
SELF="$(readlink -f "$0")"
if [[ "${HOMELABLE_SELF_DIR:-}" == "" && "$SELF" == "$APP_DIR"/* ]]; then
  self_dir="$(mktemp -d)"
  cp "$SELF" "$self_dir/update-from-fork.sh"
  export HOMELABLE_SELF_DIR="$self_dir"
  exec bash "$self_dir/update-from-fork.sh" "$@"
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
  if [[ -n "${HOMELABLE_SELF_DIR:-}" ]]; then rm -rf "$HOMELABLE_SELF_DIR"; fi
}
trap cleanup EXIT

TARBALL_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
log "Downloading ${REPO}@${BRANCH}"
curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/src.tar.gz" \
  || fail "download failed: $TARBALL_URL (is the repo public and the branch named '$BRANCH'?)"

# Unpack first, so a truncated or HTML-error download fails before the service
# is stopped and before anything under $APP_DIR is touched.
mkdir -p "$TMP_DIR/src"
tar -xzf "$TMP_DIR/src.tar.gz" --strip-components=1 -C "$TMP_DIR/src" \
  || fail "tarball did not extract — the download is probably not a tarball"
[[ -f "$TMP_DIR/src/backend/app/main.py" ]] || fail "extracted tree does not look like Homelable"

log "Stopping $SERVICE"
systemctl stop "$SERVICE" || warn "$SERVICE was not running"

# The tarball carries no .env and no data dir, so deploying over the tree keeps
# them; the backup is the escape hatch if this run goes wrong anyway.
log "Backing up config + data to $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
for path in "$APP_DIR/backend/.env" "$APP_DIR/data" "$APP_DIR/mcp/.env"; do
  [[ -e "$path" ]] && cp -a "$path" "$BACKUP_DIR/" && log "  saved $path"
done
# Also keep the previous source, so a rollback is a copy rather than a re-clone.
tar -czf "$BACKUP_DIR/previous-source.tar.gz" \
  --exclude='backend/.venv' --exclude='frontend/node_modules' \
  --exclude='frontend/dist' --exclude='data' \
  -C "$APP_DIR" . 2>/dev/null || warn "could not archive previous source (continuing)"

# Overlay rather than wipe-and-replace: the tarball has no data/, no .env, no
# .venv and no node_modules, so an overlay updates exactly the tracked files
# and leaves state alone. Files deleted upstream linger; harmless here.
log "Deploying source into $APP_DIR"
tar -czf - -C "$TMP_DIR/src" . | tar -xzf - -C "$APP_DIR"

log "Rebuilding Python dependencies"
VENV_PY="$APP_DIR/backend/.venv/bin/python"
if [[ ! -x "$VENV_PY" ]]; then
  command -v uv >/dev/null || fail "venv missing at $APP_DIR/backend/.venv and uv not available to recreate it"
  uv venv "$APP_DIR/backend/.venv"
fi
if command -v uv >/dev/null; then
  (cd "$APP_DIR/backend" && uv pip install --python "$VENV_PY" -r requirements.txt)
else
  (cd "$APP_DIR/backend" && "$APP_DIR/backend/.venv/bin/pip" install -r requirements.txt)
fi

log "Rebuilding frontend (this takes a few minutes)"
cd "$APP_DIR/frontend"
npm ci --no-audit --no-fund
npm run build
[[ -f "$APP_DIR/frontend/dist/index.html" ]] || fail "frontend build produced no dist/index.html"

if [[ -f "$APP_DIR/mcp/.env" ]] && systemctl list-unit-files | grep -q "^${MCP_SERVICE}.service"; then
  log "Rebuilding MCP server dependencies"
  if command -v uv >/dev/null && [[ -x "$APP_DIR/mcp/.venv/bin/python" ]]; then
    (cd "$APP_DIR/mcp" && uv pip install --python "$APP_DIR/mcp/.venv/bin/python" -r requirements.txt)
  fi
  systemctl restart "$MCP_SERVICE" || warn "$MCP_SERVICE failed to restart"
fi

log "Starting $SERVICE"
systemctl start "$SERVICE"
sleep 3
systemctl is-active --quiet "$SERVICE" \
  || { journalctl -u "$SERVICE" -n 40 --no-pager; fail "$SERVICE did not come up — see the log above"; }

# Prove the deployed backend really carries the nmap check, not just that the
# service restarted.
if grep -q '_nmap_ping' "$APP_DIR/backend/app/services/status_checker.py"; then
  log "nmap check method present in the deployed backend"
else
  warn "deployed backend has no nmap check — is the commit on ${REPO}@${BRANCH}?"
fi

log "Done. Backup kept at $BACKUP_DIR"
log "Note: running the CT's built-in 'update' will pull the upstream release and overwrite this. Re-run this script after that."
