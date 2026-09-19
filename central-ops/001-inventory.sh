#!/usr/bin/env bash
set -u
echo "[HOST]"
hostname
uname -a
echo
echo "[SERVICES]"
for s in corex-sync.timer corex-central-ops.timer corex-bridge corex-agent gse-corex-bridge central-backend caddy android-bridge; do
  printf "%s=" "$s"
  systemctl is-active "$s" 2>/dev/null || true
done
echo
echo "[CENTRAL_TREE]"
if [ -d /srv/apps/central ]; then
  find /srv/apps/central -maxdepth 3 -mindepth 1 -printf '%y %p\n' 2>/dev/null | sort | head -n 500
else
  echo "MISSING /srv/apps/central"
fi
echo
echo "[CENTRAL_FILES_SUMMARY]"
if [ -d /srv/apps/central ]; then
  find /srv/apps/central -type f \( -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.html' -o -name '*.css' -o -name '*.json' -o -name '*.md' \) -printf '%p %s bytes\n' 2>/dev/null | sort | head -n 500
fi
echo
echo "[PORTS]"
ss -ltnp 2>/dev/null | grep -E ':(80|443|3000|5000|8000|8080|8090|8787|9000)\\b' || true
echo
echo "[PROCESSES]"
ps -eo pid,comm,args 2>/dev/null | grep -E 'corex|central' | grep -v grep || true
