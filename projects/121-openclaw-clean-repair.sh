#!/usr/bin/env bash
set -euo pipefail

USER_NAME=ubuntu
HOME_DIR=/home/ubuntu
PREFIX=/home/ubuntu/.npm-global
UID_NUM="$(id -u "$USER_NAME")"
RUNTIME_DIR="/run/user/$UID_NUM"

as_ubuntu() {
  runuser -u "$USER_NAME" -- env     HOME="$HOME_DIR"     PATH="$PREFIX/bin:/usr/local/bin:/usr/bin:/bin"     XDG_RUNTIME_DIR="$RUNTIME_DIR"     "$@"
}

echo "=== STOP GATEWAY ==="
as_ubuntu systemctl --user stop openclaw-gateway.service 2>/dev/null || true

echo "=== FIX OWNERSHIP / CLEAN BROKEN PACKAGE ==="
mkdir -p "$HOME_DIR/.npm" "$PREFIX"
chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR/.npm" "$PREFIX"
rm -rf "$PREFIX/lib/node_modules/openclaw"
rm -f "$PREFIX/bin/openclaw"
rm -rf "$HOME_DIR/.npm/_cacache"
mkdir -p "$HOME_DIR/.npm/_cacache"
chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR/.npm" "$PREFIX"

echo "=== INSTALL OPENCLAW 2026.9.4 ==="
as_ubuntu npm config set prefix "$PREFIX"
as_ubuntu npm install -g openclaw@2026.9.4 --force

echo "=== VERIFY BINARY ==="
test -x "$PREFIX/bin/openclaw"
"$PREFIX/bin/openclaw" --version

echo "=== START GATEWAY ==="
as_ubuntu systemctl --user daemon-reload
as_ubuntu systemctl --user restart openclaw-gateway.service

for i in $(seq 1 30); do
  if ss -ltn 2>/dev/null | grep -q ':18789 '; then
    break
  fi
  sleep 1
done

echo "=== SERVICE ==="
as_ubuntu systemctl --user is-active openclaw-gateway.service

echo "=== PORT ==="
ss -ltnp 2>/dev/null | grep 18789 || true

echo "=== RECENT ERRORS ==="
RECENT="$(as_ubuntu journalctl --user -u openclaw-gateway.service --since '2 minutes ago' --no-pager 2>/dev/null || true)"
printf '%s
' "$RECENT" | tail -n 40
if printf '%s
' "$RECENT" | grep -Eq 'ERR_MODULE_NOT_FOUND|Permission denied|EACCES'; then
  echo "OPENCLAW_REPAIR_FAILED_RECENT_ERRORS"
  exit 1
fi

if ! ss -ltn 2>/dev/null | grep -q ':18789 '; then
  echo "OPENCLAW_REPAIR_FAILED_NO_PORT"
  exit 1
fi

echo OPENCLAW_2026_9_4_REPAIRED
