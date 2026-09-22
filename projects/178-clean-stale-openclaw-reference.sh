#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Interfaz/server.py
NATIVE=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/interfaz-openclaw-string-cleanup-$STAMP

mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. REMOVE STALE OPENCLAW KEYWORD FROM INTERFAZ HEURISTICS ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

s=s.replace('"central","openclaw","vm","servicio","systemd","caddy","api","backend","frontend",',
            '"central","vm","servicio","systemd","caddy","api","backend","frontend",')

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"

if grep -qiE 'openclaw|127\.0\.0\.1:18789' "$SERVER"; then
  echo "ERROR: OpenClaw reference remains in Interfaz"
  grep -niE 'openclaw|127\.0\.0\.1:18789' "$SERVER" || true
  exit 1
fi

echo INTERFAZ_OPENCLAW_DEPENDENCY_REMOVED_OK

echo "=== 2. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/interfaz-openclaw-clean-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/interfaz-openclaw-clean-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_NATIVE_CHAT_SERVICE_OK

echo "=== 3. REAL INTERFAZ CHAT RETEST ==="
CHATREQ=/tmp/interfaz-native-chat-retest.json
cat >"$CHATREQ" <<'JSON'
{"text":"Respondé exactamente INTERFAZ_NATIVE_CHAT_OK"}
JSON
CHAT=$(curl -fsS --max-time 150 -H 'Content-Type: application/json' --data-binary @"$CHATREQ" http://127.0.0.1:8791/api/message)
echo "$CHAT"
CHAT_JSON="$CHAT" python3 - <<'PY'
import json,os
x=json.loads(os.environ["CHAT_JSON"])
assert x["ok"] is True,x
assert x["mode"]=="chat",x
assert "INTERFAZ_NATIVE_CHAT_OK" in x["answer"],x
print("INTERFAZ_NATIVE_CHAT_LIVE_OK")
PY

echo "=== 4. OPERATIONAL PATH REGRESSION ==="
OPREQ=/tmp/interfaz-native-operational-retest.json
cat >"$OPREQ" <<'JSON'
{"text":"Creá el archivo native-chat-regression.txt que contenga exactamente NATIVE_CHAT_OPERATIONAL_OK, leelo y verificá que coincida."}
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
n=(j.get("result") or {}).get("native") or {}
assert n.get("capability")=="programacion",n
print("INTERFAZ_OPERATIONAL_PATH_REGRESSION_OK")
PY
grep -qx 'NATIVE_CHAT_OPERATIONAL_OK' "/home/ubuntu/Central/work/$JOB/native-chat-regression.txt"

echo "=== 5. OPENCLAW STATUS (ROLLBACK ONLY) ==="
systemctl --user is-active openclaw-gateway.service 2>/dev/null || true
echo OPENCLAW_NOT_IN_INTERFAZ_PATH

cat >"$NATIVE/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "interfaz-native-chat-v1-cleanup",
  "normal_conversation": "Central Native",
  "operational_execution": "Central Jobs -> Central Native",
  "openclaw_in_interfaz_path": false,
  "openclaw_installation_kept_for_rollback": true,
  "active": true
}
EOF

echo CENTRAL_INTERFAZ_NATIVE_CHAT_V1_READY
echo "backup=$BACKUP"
