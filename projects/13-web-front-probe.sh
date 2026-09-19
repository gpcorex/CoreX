#!/usr/bin/env bash
set -euo pipefail

OUT="/srv/apps/android-bridge/data/web-front.txt"
mkdir -p "$(dirname "$OUT")"

{
  echo "WEB_FRONT_PROBE"
  echo "date=$(date -Is)"
  echo
  echo "[PORT80]"
  ss -ltnp | grep ':80 ' || true
  echo
  echo "[PORT443]"
  ss -ltnp | grep ':443 ' || true
  echo
  echo "[NGINX]"
  systemctl is-active nginx 2>/dev/null || true
  echo
  echo "[APACHE]"
  systemctl is-active apache2 2>/dev/null || true
  echo
  echo "[CADDY]"
  systemctl is-active caddy 2>/dev/null || true
  echo
  echo "[NGINX_ENABLED]"
  ls -la /etc/nginx/sites-enabled 2>/dev/null || true
} >"$OUT"

echo "WEB_FRONT_PROBE_OK"
