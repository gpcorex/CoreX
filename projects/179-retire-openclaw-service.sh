#!/usr/bin/env bash
set -euo pipefail

NATIVE=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/openclaw-retire-$STAMP
mkdir -p "$BACKUP"

echo "=== 1. PRECHECK: NO OPENCLAW IN ACTIVE INTERFAZ / EXECUTOR PATH ==="
grep -qiE 'openclaw|127\.0\.0\.1:18789' /home/ubuntu/Interfaz/server.py && {
  echo "OPENCLAW_REFERENCE_FOUND_IN_INTERFAZ"
  exit 1
} || true
grep -qiE 'openclaw|18789' /home/ubuntu/Central/runtime/executor.js && {
  echo "OPENCLAW_REFERENCE_FOUND_IN_EXECUTOR"
  exit 1
} || true
echo ACTIVE_PATH_OPENCLAW_FREE_OK

echo "=== 2. RECORD CURRENT OPENCLAW STATE ==="
systemctl --user status openclaw-gateway.service --no-pager >"$BACKUP/openclaw-status-before.txt" 2>&1 || true
systemctl --user is-enabled openclaw-gateway.service >"$BACKUP/openclaw-enabled-before.txt" 2>&1 || true
systemctl --user is-active openclaw-gateway.service >"$BACKUP/openclaw-active-before.txt" 2>&1 || true
echo OPENCLAW_STATE_SAVED

echo "=== 3. STOP + DISABLE OPENCLAW GATEWAY ==="
systemctl --user disable --now openclaw-gateway.service 2>/dev/null || true
sleep 2
ACTIVE=$(systemctl --user is-active openclaw-gateway.service 2>/dev/null || true)
ENABLED=$(systemctl --user is-enabled openclaw-gateway.service 2>/dev/null || true)
echo "active=$ACTIVE"
echo "enabled=$ENABLED"
if [ "$ACTIVE" = "active" ]; then
  echo "OPENCLAW_STILL_ACTIVE"
  exit 1
fi
echo OPENCLAW_STOPPED_DISABLED_OK

echo "=== 4. VERIFY PORT 18789 IS CLOSED ==="
if ss -ltn | grep -q ':18789\b'; then
  echo "PORT_18789_STILL_LISTENING"
  ss -ltnp | grep ':18789\b' || true
  exit 1
fi
echo OPENCLAW_PORT_CLOSED_OK

echo "=== 5. INTERFAZ NORMAL CHAT WITHOUT OPENCLAW ==="
CHATREQ=/tmp/openclaw-retire-chat.json
cat >"$CHATREQ" <<'JSON'
{"text":"Respondé exactamente NATIVE_CHAT_WITHOUT_OPENCLAW_OK"}
JSON
CHAT=$(curl -fsS --max-time 150 -H 'Content-Type: application/json' --data-binary @"$CHATREQ" http://127.0.0.1:8791/api/message)
echo "$CHAT"
CHAT_JSON="$CHAT" python3 - <<'PY'
import json,os
x=json.loads(os.environ["CHAT_JSON"])
assert x["ok"] is True,x
assert x["mode"]=="chat",x
assert "NATIVE_CHAT_WITHOUT_OPENCLAW_OK" in x["answer"],x
print("CHAT_WITHOUT_OPENCLAW_OK")
PY

echo "=== 6. OPERATIONAL JOB WITHOUT OPENCLAW ==="
OPREQ=/tmp/openclaw-retire-job.json
cat >"$OPREQ" <<'JSON'
{"text":"Creá el archivo openclaw-retired.txt que contenga exactamente OPENCLAW_RETIRED_OK, ejecutá la verificación y confirmá que coincida."}
JSON
OP=$(curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @"$OPREQ" http://127.0.0.1:8791/api/message)
echo "$OP"
JOB=$(OP_JSON="$OP" python3 - <<'PY'
import json,os
x=json.loads(os.environ["OP_JSON"])
assert x["ok"] is True,x
assert x["mode"]=="job",x
print(x["job_id"])
PY
)

for i in $(seq 1 120); do
  J=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB")
  S=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$J")
  printf '\rstatus=%s elapsed=%ss' "$S" "$i"
  case "$S" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
echo
J_JSON="$J" python3 - <<'PY'
import json,os
j=json.loads(os.environ["J_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
r=j.get("result") or {}
assert r.get("jugador")=="Central Native",r
assert "openclaw" not in json.dumps(r).lower(),r
print("JOB_WITHOUT_OPENCLAW_OK")
PY
grep -qx 'OPENCLAW_RETIRED_OK' "/home/ubuntu/Central/work/$JOB/openclaw-retired.txt"

echo "=== 7. VOICE + ATTACHMENT ENDPOINT HEALTH ==="
curl -fsS --max-time 5 http://127.0.0.1:8791/api/health >/dev/null
grep -q '/api/transcribe' /home/ubuntu/Interfaz/server.py
grep -q '/api/attachments' /home/ubuntu/Interfaz/server.py
echo INTERFAZ_FEATURES_PRESENT_OK

cat >"$NATIVE/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "openclaw-retired",
  "openclaw_service_active": false,
  "openclaw_service_enabled": false,
  "openclaw_files_deleted": false,
  "rollback_files_kept": true,
  "normal_chat_without_openclaw": true,
  "operational_jobs_without_openclaw": true,
  "active": true
}
EOF

echo CENTRAL_OPENCLAW_RETIRED_READY
echo "backup=$BACKUP"
echo "NOTE=OpenClaw files remain installed for rollback, but its gateway is stopped and disabled."
