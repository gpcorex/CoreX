#!/usr/bin/env bash
set -euo pipefail

OUT="/srv/apps/android-bridge/data/caddy.txt"
mkdir -p "$(dirname "$OUT")"

{
  echo "CADDY_PROBE"
  echo "date=$(date -Is)"
  echo
  echo "[STATUS]"
  systemctl is-active caddy || true
  echo
  echo "[CADDYFILE]"
  if [ -f /etc/caddy/Caddyfile ]; then
    cat /etc/caddy/Caddyfile
  else
    echo "NO_CADDYFILE"
  fi
} >"$OUT"

echo "CADDY_PROBE_OK"
