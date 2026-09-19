#!/usr/bin/env bash
set -u

ROOT="/opt/corex/repo"
REPORT="$ROOT/COREX_CENTRAL_STATUS.txt"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

{
  echo "COREX_CENTRAL_STATUS"
  echo "generated_at=$(date -Is)"
  echo "host=$(hostname)"
  echo "repo_head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  echo
  echo "[SERVICES]"
  for s in corex-bridge corex-agent gse-corex-bridge central-backend caddy; do
    printf "%s=" "$s"
    systemctl is-active "$s" 2>/dev/null || true
  done
  echo
  echo "[CENTRAL_PATHS]"
  for p in /srv/apps/central /opt/corex/repo /srv/apps; do
    if [ -e "$p" ]; then
      echo "$p=present"
    else
      echo "$p=missing"
    fi
  done
  echo
  echo "[CENTRAL_TOPLEVEL]"
  if [ -d /srv/apps/central ]; then
    find /srv/apps/central -maxdepth 2 -mindepth 1 -printf '%y %p\n' 2>/dev/null | sort | head -n 250
  fi
  echo
  echo "[LISTENING_PORTS]"
  ss -ltnp 2>/dev/null | grep -E ':(80|443|8090|8787|3000|5000|8000|8080|9000)\\b' || true
  echo
  echo "[COREX_PROCESSES]"
  ps -eo pid,comm,args 2>/dev/null | grep -E 'corex|central' | grep -v grep || true
  echo
  echo "[CADDY_ROUTES]"
  if [ -f /etc/caddy/Caddyfile ]; then
    grep -E '^[[:space:]]*(https?://|[a-zA-Z0-9.-]+[[:space:]]*\\{|route |handle |reverse_proxy )' /etc/caddy/Caddyfile 2>/dev/null || true
  fi
} >"$TMP"

cp "$TMP" "$REPORT"

cd "$ROOT"
git add COREX_CENTRAL_STATUS.txt
if git diff --cached --quiet; then
  echo "COREX_CENTRAL_STATUS_NO_CHANGE"
  exit 0
fi

git -c user.name='CoreX VM' -c user.email='corex-vm@local' commit -m 'Report live Central status from CoreX VM' >/dev/null 2>&1 || {
  echo "COREX_CENTRAL_STATUS_COMMIT_FAILED"
  exit 0
}

if git push origin HEAD:main >/dev/null 2>&1; then
  echo "COREX_CENTRAL_STATUS_PUSHED"
else
  echo "COREX_CENTRAL_STATUS_PUSH_FAILED"
fi
