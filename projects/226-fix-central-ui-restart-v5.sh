#!/usr/bin/env bash
set -euo pipefail

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/central-auditor-nav-v5-$STAMP
mkdir -p "$BACKUP"

echo "=== 1. CHECK WHETHER RESTART IS ACTUALLY NEEDED ==="
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/ >/tmp/central-home-v5.html
if grep -q 'CENTRAL_AUDITOR_NAV_V4' /tmp/central-home-v5.html && grep -q 'href="/central/auditor/"' /tmp/central-home-v5.html; then
  echo CENTRAL_UI_STATIC_CHANGE_ALREADY_LIVE_OK
  NEED_RESTART=0
else
  echo CENTRAL_UI_STATIC_CHANGE_NOT_LIVE_YET
  NEED_RESTART=1
fi

echo "=== 2. IDENTIFY ACTUAL 8090 OWNER ==="
PID=$(sudo lsof -t -iTCP:8090 -sTCP:LISTEN 2>/dev/null | head -n1 || true)
if [ -z "$PID" ]; then
  echo CENTRAL_8090_PID_NOT_FOUND
  exit 1
fi
echo "pid=$PID"
ps -o pid,ppid,user,cmd -p "$PID" || true
PPIDV=$(ps -o ppid= -p "$PID" | tr -d ' ' || true)
if [ -n "$PPIDV" ]; then
  ps -o pid,ppid,user,cmd -p "$PPIDV" || true
fi

echo "=== 3. RESTART ONLY IF REQUIRED ==="
if [ "$NEED_RESTART" -eq 1 ]; then
  RESTARTED=0

  # System-level service candidates.
  for u in central-ui.service central-backend.service central.service; do
    if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "$u"; then
      echo "restarting_system_unit=$u"
      systemctl restart "$u"
      RESTARTED=1
      break
    fi
  done

  # User-level systemd service under ubuntu.
  if [ "$RESTARTED" -eq 0 ]; then
    UIDU=$(id -u ubuntu)
    export XDG_RUNTIME_DIR="/run/user/$UIDU"
    for u in central-ui.service central-backend.service central.service; do
      if runuser -u ubuntu -- env HOME=/home/ubuntu XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "$u"; then
        echo "restarting_user_unit=$u"
        runuser -u ubuntu -- env HOME=/home/ubuntu XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user restart "$u"
        RESTARTED=1
        break
      fi
    done
  fi

  # PM2 fallback if present.
  if [ "$RESTARTED" -eq 0 ] && command -v pm2 >/dev/null 2>&1; then
    if sudo -u ubuntu pm2 jlist 2>/dev/null | grep -q '/home/ubuntu/Central/app/server.js'; then
      NAME=$(sudo -u ubuntu pm2 jlist | python3 - <<'PY'
import json,sys
x=json.load(sys.stdin)
for p in x:
    env=p.get("pm2_env") or {}
    args=" ".join(str(a) for a in (env.get("args") or []))
    exe=str(env.get("pm_exec_path") or "")
    if "/home/ubuntu/Central/app/server.js" in exe or "/home/ubuntu/Central/app/server.js" in args:
        print(p.get("name") or p.get("pm_id"))
        break
PY
)
      if [ -n "$NAME" ]; then
        echo "restarting_pm2=$NAME"
        sudo -u ubuntu pm2 restart "$NAME"
        RESTARTED=1
      fi
    fi
  fi

  if [ "$RESTARTED" -eq 0 ]; then
    echo CENTRAL_UI_RESTART_OWNER_NOT_FOUND
    echo "--- cgroup ---"
    cat "/proc/$PID/cgroup" 2>/dev/null || true
    echo "--- parent chain ---"
    ps -ef | grep -E 'Central/app/server.js|node' | grep -v grep || true
    exit 1
  fi

  for i in $(seq 1 30); do
    if curl -fsS --max-time 3 https://cen-tral.duckdns.org/central/ >/tmp/central-home-v5.html 2>/dev/null; then
      if grep -q 'CENTRAL_AUDITOR_NAV_V4' /tmp/central-home-v5.html; then break; fi
    fi
    sleep 1
  done
fi

echo "=== 4. VERIFY CENTRAL HOME ENTRY ==="
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/ >/tmp/central-home-v5.html
grep -q 'CENTRAL_AUDITOR_NAV_V4' /tmp/central-home-v5.html
grep -q 'href="/central/auditor/"' /tmp/central-home-v5.html
echo CENTRAL_HOME_AUDITOR_ENTRY_V5_OK

echo "=== 5. VERIFY NESTED AUDITOR ==="
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/ | grep -q 'Central · APK / XAPK'
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo CENTRAL_NESTED_AUDITOR_PUBLIC_V5_OK

echo CENTRAL_AUDITOR_NAV_V5_READY
echo "URL=https://cen-tral.duckdns.org/central/"
echo "AUDITOR=https://cen-tral.duckdns.org/central/auditor/"
echo "backup=$BACKUP"
