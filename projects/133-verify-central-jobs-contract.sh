#!/usr/bin/env bash
set -euo pipefail
APP=/home/ubuntu/Central/runtime/jobs_api.py

echo "=== CENTRAL JOBS HEALTH ==="
curl -fsS --max-time 5 http://127.0.0.1:8091/api/health
echo

echo "=== CONTRACT MARKERS ==="
grep -q 'TR-CENTRAL-' "$APP"
grep -q 'job\["status"\]="ANALIZANDO"' "$APP"
grep -q '"source":str(body.get("source") or "chat")' "$APP"
echo "CONTRACT_MARKERS_OK"

echo "=== DIRECT CONTRACT TEST ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá /tmp/central-contract-verify.txt con el texto CENTRAL_CONTRACT_OK y verificá","source":"chat","project":"Central","conversation_id":"contract-verify"}' \
  http://127.0.0.1:8091/api/jobs)
echo "$RESP"
JOB_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP")

for i in $(seq 1 30); do
  OUT=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB_ID")
  STATUS=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
  case "$STATUS" in COMPLETADA|ERROR) break ;; esac
  sleep 1
done

echo "$OUT"
OUT_JSON="$OUT" python3 - <<'PY'
import json,os
o=json.loads(os.environ["OUT_JSON"])
j=o["job"]
assert j["id"].startswith("TR-CENTRAL-"), j["id"]
assert j["status"]=="COMPLETADA", j
assert j.get("source")=="chat", j
assert j.get("result",{}).get("resultado")=="CENTRAL_STATUS=COMPLETADO", j
assert j.get("mode")=="DIRECT", j
print("CENTRAL_JOBS_CONTRACT_OK")
PY

echo CENTRAL_JOBS_VERIFIED
