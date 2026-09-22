#!/usr/bin/env bash
set -euo pipefail

PORT=18789
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/openclaw-port-cleanup-$STAMP
mkdir -p "$BACKUP"

echo "=== 1. IDENTIFY LISTENER ON PORT 18789 ==="
PIDS=$(ss -ltnp 2>/dev/null | awk '/:18789[[:space:]]/ {match($0,/pid=([0-9]+)/,m); if(m[1]) print m[1]}' | sort -u || true)
if [ -z "$PIDS" ]; then
  echo "NO_LISTENER_FOUND"
else
  for pid in $PIDS; do
    echo "pid=$pid"
    ps -o pid,ppid,user,lstart,cmd -p "$pid" | tee -a "$BACKUP/processes-before.txt" || true
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | tee -a "$BACKUP/cmdline-before.txt" || true
    echo | tee -a "$BACKUP/cmdline-before.txt"
    cat "/proc/$pid/cgroup" 2>/dev/null | tee -a "$BACKUP/cgroup-before.txt" || true
  done
fi
echo OPENCLAW_LISTENER_IDENTIFIED_OK

echo "=== 2. STOP ANY KNOWN OPENCLAW USER UNITS ==="
systemctl --user list-unit-files --type=service --no-pager 2>/dev/null | awk 'tolower($1) ~ /openclaw/ {print $1}' | tee "$BACKUP/openclaw-units.txt" || true
while read -r unit; do
  [ -n "$unit" ] || continue
  systemctl --user disable --now "$unit" 2>/dev/null || true
done < "$BACKUP/openclaw-units.txt"

echo "=== 3. TERMINATE ONLY THE PROCESS LISTENING ON 18789 ==="
PIDS=$(ss -ltnp 2>/dev/null | awk '/:18789[[:space:]]/ {match($0,/pid=([0-9]+)/,m); if(m[1]) print m[1]}' | sort -u || true)
for pid in $PIDS; do
  CMD=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
  echo "listener_pid=$pid cmd=$CMD"
  if printf '%s' "$CMD" | grep -qiE 'openclaw|gateway|18789'; then
    kill -TERM "$pid" 2>/dev/null || true
  else
    echo "REFUSING_TO_KILL_UNKNOWN_PROCESS pid=$pid"
    exit 1
  fi
done

for i in $(seq 1 15); do
  if ! ss -ltnp 2>/dev/null | grep -q ':18789\b'; then break; fi
  sleep 1
done

if ss -ltnp 2>/dev/null | grep -q ':18789\b'; then
  PIDS=$(ss -ltnp 2>/dev/null | awk '/:18789[[:space:]]/ {match($0,/pid=([0-9]+)/,m); if(m[1]) print m[1]}' | sort -u || true)
  for pid in $PIDS; do
    CMD=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
    if printf '%s' "$CMD" | grep -qiE 'openclaw|gateway|18789'; then
      kill -KILL "$pid" 2>/dev/null || true
    else
      echo "REFUSING_TO_KILL_UNKNOWN_PROCESS pid=$pid"
      exit 1
    fi
  done
fi

sleep 2
if ss -ltnp 2>/dev/null | grep -q ':18789\b'; then
  echo "PORT_18789_STILL_LISTENING_AFTER_KILL"
  ss -ltnp | grep ':18789\b' || true
  exit 1
fi
echo OPENCLAW_PORT_CLOSED_OK

echo "=== 4. WAIT AND VERIFY IT DOES NOT RESPAWN ==="
sleep 8
if ss -ltnp 2>/dev/null | grep -q ':18789\b'; then
  echo "OPENCLAW_RESPAWNED"
  ss -ltnp | grep ':18789\b' || true
  exit 1
fi
echo OPENCLAW_NO_RESPAWN_OK

echo "=== 5. CHAT REGRESSION WITHOUT OPENCLAW ==="
REQ=/tmp/openclaw-cleanup-chat.json
cat >"$REQ" <<'JSON'
{"text":"Respondé exactamente OPENCLAW_PORT_CLEANUP_CHAT_OK"}
JSON
OUT=$(curl -fsS --max-time 150 -H 'Content-Type: application/json' --data-binary @"$REQ" http://127.0.0.1:8791/api/message)
echo "$OUT"
OUT_JSON="$OUT" python3 - <<'PY'
import json,os
x=json.loads(os.environ["OUT_JSON"])
assert x.get("ok") is True,x
assert x.get("mode")=="chat",x
assert "OPENCLAW_PORT_CLEANUP_CHAT_OK" in x.get("answer",""),x
print("CHAT_AFTER_OPENCLAW_KILL_OK")
PY

echo "=== 6. FINAL STATUS ==="
echo "port_18789=closed"
echo "openclaw_user_units:"
systemctl --user list-units --type=service --all --no-pager 2>/dev/null | grep -i openclaw || true
echo CENTRAL_OPENCLAW_PORT_CLEANUP_READY
echo "backup=$BACKUP"
