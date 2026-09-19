#!/usr/bin/env bash
set -u

OUT="/srv/apps/android-bridge/www/central-status.txt"
mkdir -p "$(dirname "$OUT")"

{
  echo "COREX_CENTRAL_STATUS"
  echo "generated_at=$(date -Is)"
  echo "host=$(hostname)"
  echo "repo_head=$(git -C /opt/corex/repo rev-parse HEAD 2>/dev/null || true)"
  echo
  echo "[SERVICES]"
  for s in corex-sync.timer corex-sync.service corex-bridge corex-agent gse-corex-bridge central-backend caddy android-bridge; do
    printf "%s=" "$s"
    systemctl is-active "$s" 2>/dev/null || true
  done
  echo
  echo "[CENTRAL_PATHS]"
  for p in /srv/apps/central /opt/corex/repo /srv/apps; do
    if [ -e "$p" ]; then echo "$p=present"; else echo "$p=missing"; fi
  done
  echo
  echo "[CENTRAL_TOPLEVEL]"
  if [ -d /srv/apps/central ]; then
    find /srv/apps/central -maxdepth 2 -mindepth 1 -printf '%y %p\n' 2>/dev/null | sort | head -n 300
  fi
  echo
  echo "[LISTENING_PORTS]"
  ss -ltnp 2>/dev/null | grep -E ':(80|443|8090|8787|3000|5000|8000|8080|9000)\\b' || true
  echo
  echo "[COREX_PROCESSES]"
  ps -eo pid,comm,args 2>/dev/null | grep -E 'corex|central' | grep -v grep || true
} >"$OUT"

chmod 644 "$OUT"
echo "CENTRAL_STATUS_PUBLISHED"
