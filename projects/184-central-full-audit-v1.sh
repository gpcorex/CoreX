#!/usr/bin/env bash
set -euo pipefail

STAMP=$(date +%Y%m%d-%H%M%S)
OUTDIR=/home/ubuntu/Central/audits/current-$STAMP
STATE=/home/ubuntu/Central/state
mkdir -p "$OUTDIR"

echo "=== 1. SYSTEM BASE ==="
{
  echo "date=$(date -Is)"
  echo "host=$(hostname)"
  echo "user=$(whoami)"
  echo "kernel=$(uname -r)"
  echo
  free -h
  echo
  df -h /
} | tee "$OUTDIR/system.txt"
echo SYSTEM_BASE_AUDIT_OK

echo "=== 2. SERVICES ==="
for s in caddy central-jobs-api.service interfaz.service; do
  printf '%-30s ' "$s"
  systemctl is-active "$s" 2>/dev/null || true
done | tee "$OUTDIR/services.txt"

{
  echo "openclaw_user_active=$(systemctl --user is-active openclaw-gateway.service 2>/dev/null || true)"
  echo "openclaw_user_enabled=$(systemctl --user is-enabled openclaw-gateway.service 2>/dev/null || true)"
} | tee -a "$OUTDIR/services.txt"
echo SERVICES_AUDIT_OK

echo "=== 3. PORTS ==="
ss -ltnp | grep -E ':(80|443|8090|8091|8791|18789)\b' | tee "$OUTDIR/ports.txt" || true
if ss -ltnp | grep -q ':18789\b'; then
  echo "ERROR_OPENCLAW_PORT_LISTENING"
  exit 1
fi
echo PORT_AUDIT_OK

echo "=== 4. TIMERS ==="
systemctl list-timers --all --no-pager | grep -Ei 'corex|conector|central|interfaz|openclaw' | tee "$OUTDIR/timers.txt" || true
echo TIMERS_AUDIT_OK

echo "=== 5. ACTIVE EXECUTION PATH REFERENCES ==="
{
  echo "--- Interfaz ---"
  grep -niE 'openclaw|18789' /home/ubuntu/Interfaz/server.py || true
  echo "--- Central executor ---"
  grep -niE 'openclaw|18789' /home/ubuntu/Central/runtime/executor.js || true
} | tee "$OUTDIR/openclaw-active-path.txt"
if grep -qiE 'openclaw|18789' /home/ubuntu/Interfaz/server.py /home/ubuntu/Central/runtime/executor.js; then
  echo "ERROR_OPENCLAW_ACTIVE_REFERENCE"
  exit 1
fi
echo ACTIVE_PATH_NATIVE_ONLY_OK

echo "=== 6. HEALTH ENDPOINTS ==="
curl -fsS --max-time 5 http://127.0.0.1:8091/api/health | tee "$OUTDIR/central-jobs-health.json"
echo
curl -fsS --max-time 5 http://127.0.0.1:8791/api/health | tee "$OUTDIR/interfaz-health.json"
echo
curl -fsSI --max-time 10 https://cen-tral.duckdns.org/central/ | head -n 1 | tee "$OUTDIR/central-public-head.txt"
curl -fsSI --max-time 10 https://cen-tral.duckdns.org/interfaz/ | head -n 1 | tee "$OUTDIR/interfaz-public-head.txt"
echo HEALTH_ENDPOINTS_OK

echo "=== 7. PWA IDENTITIES ==="
curl -fsS --max-time 15 https://cen-tral.duckdns.org/manifest.webmanifest >"$OUTDIR/root-manifest.json" || true
curl -fsS --max-time 15 https://cen-tral.duckdns.org/interfaz/manifest.webmanifest >"$OUTDIR/chat-manifest.json"

python3 - "$OUTDIR/root-manifest.json" "$OUTDIR/chat-manifest.json" <<'PY'
import json,sys,os
root_path,chat_path=sys.argv[1:]
if os.path.getsize(root_path):
    root=json.load(open(root_path,encoding="utf-8"))
    assert root.get("id")=="/central/",root
    assert root.get("start_url")=="/central/",root
    assert root.get("scope")=="/central/",root
    print("root_pwa=Central id=/central/")
else:
    raise SystemExit("ROOT_MANIFEST_EMPTY")
chat=json.load(open(chat_path,encoding="utf-8"))
assert chat.get("id")=="/interfaz/",chat
assert chat.get("start_url")=="/interfaz/",chat
assert chat.get("scope")=="/interfaz/",chat
print("chat_pwa=Central Chat id=/interfaz/")
print("PWA_IDENTITIES_OK")
PY

echo "=== 8. NATIVE STACK FILES ==="
for f in   config.py providers.py router.py tools.py agent.py cli.py   capability_verify.py capability_status.py router_status.py   transcribe.py voice_stt_verify.py attachment_vision.py native_chat.py; do
  test -f "/home/ubuntu/Central/native_v1/$f"
  echo "$f=present"
done | tee "$OUTDIR/native-files.txt"
echo NATIVE_STACK_FILES_OK

echo "=== 9. PYTHON COMPILE CHECK ==="
python3 -m py_compile   /home/ubuntu/Interfaz/server.py   /home/ubuntu/Central/runtime/native_executor.py   /home/ubuntu/Central/native_v1/*.py
echo PYTHON_COMPILE_AUDIT_OK

echo "=== 10. ROUTER / PROVIDERS STATUS ==="
sudo -u ubuntu env PYTHONPATH=/home/ubuntu/Central/native_v1   python3 /home/ubuntu/Central/native_v1/router_status.py | tee "$OUTDIR/router-status.txt"
echo ROUTER_STATUS_AUDIT_OK

echo "=== 11. FUNCTIONAL CHAT CANARY ==="
REQ=/tmp/audit-chat.json
cat >"$REQ" <<'JSON'
{"text":"Respondé exactamente AUDIT_CHAT_OK"}
JSON
CHAT=$(curl -fsS --max-time 120 -H 'Content-Type: application/json' --data-binary @"$REQ" http://127.0.0.1:8791/api/message)
echo "$CHAT" | tee "$OUTDIR/chat-canary.json"
CHAT_JSON="$CHAT" python3 - <<'PY'
import json,os
x=json.loads(os.environ["CHAT_JSON"])
assert x.get("ok") is True,x
assert x.get("mode")=="chat",x
assert "AUDIT_CHAT_OK" in x.get("answer",""),x
print("CHAT_CANARY_OK")
PY

echo "=== 12. FUNCTIONAL JOB CANARY ==="
REQ2=/tmp/audit-job.json
cat >"$REQ2" <<'JSON'
{"text":"Creá audit-native.txt con el texto AUDIT_NATIVE_OK, leelo y verificá que coincida exactamente."}
JSON
JOBRESP=$(curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @"$REQ2" http://127.0.0.1:8791/api/message)
echo "$JOBRESP" | tee "$OUTDIR/job-submit.json"
JOB=$(JOB_JSON="$JOBRESP" python3 - <<'PY'
import json,os
x=json.loads(os.environ["JOB_JSON"])
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
echo "$J" >"$OUTDIR/job-final.json"
J_JSON="$J" python3 - <<'PY'
import json,os
j=json.loads(os.environ["J_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
r=j.get("result") or {}
assert r.get("jugador")=="Central Native",r
n=r.get("native") or {}
assert n.get("status")=="ok",n
assert n.get("capability")=="programacion",n
print("JOB_CANARY_OK")
print("model_ref="+str(n.get("model_ref")))
PY
grep -qx 'AUDIT_NATIVE_OK' "/home/ubuntu/Central/work/$JOB/audit-native.txt"
echo JOB_FILE_VERIFY_OK

echo "=== 13. FEATURE MARKERS ==="
grep -q '/api/transcribe' /home/ubuntu/Interfaz/server.py
grep -q '/api/attachments' /home/ubuntu/Interfaz/server.py
grep -q 'CENTRAL_ATTACHMENTS_B64' /home/ubuntu/Interfaz/server.py
grep -q 'staged_attachments' /home/ubuntu/Central/runtime/native_executor.py
grep -q 'serviceWorker.register' /home/ubuntu/Interfaz/server.py
echo "voice=yes"
echo "attachments=yes"
echo "operational_attachments=yes"
echo "pwa=yes"
echo FEATURE_MARKERS_OK

echo "=== 14. CANONICAL SNAPSHOT ==="
python3 - "$OUTDIR" <<'PY'
import json,sys,time,subprocess
from pathlib import Path
out=Path(sys.argv[1])
router=(out/"router-status.txt").read_text(encoding="utf-8",errors="replace")
snapshot={
  "generated_at":int(time.time()),
  "architecture":{
    "conversation":"Interfaz -> Central Native",
    "operations":"Interfaz -> Central Jobs -> Central Native -> Router -> Providers -> tools -> workspace",
    "openclaw_active":False,
  },
  "services":{
    "caddy":True,
    "central_jobs":True,
    "interfaz":True,
  },
  "pwa":{
    "central":{"id":"/central/","start_url":"/central/","scope":"/central/"},
    "chat":{"id":"/interfaz/","start_url":"/interfaz/","scope":"/interfaz/"}
  },
  "features":{
    "text":True,
    "voice_stt":True,
    "attachments":True,
    "vision":True,
    "pdf_text":True,
    "operational_raw_files":True
  },
  "router_status_raw":router,
}
(out/"CANONICAL_STATE.json").write_text(json.dumps(snapshot,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("CANONICAL_STATE_WRITTEN="+str(out/"CANONICAL_STATE.json"))
PY

echo CENTRAL_FULL_AUDIT_V1_READY
echo "audit_dir=$OUTDIR"
