#!/usr/bin/env bash
set -euo pipefail

EXEC=/home/ubuntu/Central/runtime/executor.js
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-canary-source-fix-$STAMP

mkdir -p "$BACKUP"
cp -a "$EXEC" "$BACKUP/executor.js"

echo "=== 1. PATCH CANARY SOURCE RESOLUTION ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/runtime/executor.js")
s=p.read_text(encoding="utf-8")
old='''const source=String(task.source || (task.contexto&&task.contexto.source) || "");
const useNative=(source==="native-smoke" || source==="native-canary");
'''
new='''let source=String(task.source || (task.contexto&&task.contexto.source) || "");
const trabajo=String(task.trabajo || task.job_id || "");
if(trabajo){
  try{
    const jobPath="/home/ubuntu/Central/data/api-jobs/"+trabajo+"/job.json";
    const job=JSON.parse(fs.readFileSync(jobPath,"utf8"));
    if(job && job.source) source=String(job.source);
  }catch(e){}
}
const useNative=(source==="native-smoke" || source==="native-canary");
'''
if old not in s:
    raise SystemExit("CANARY_SOURCE_ANCHOR_NOT_FOUND")
p.write_text(s.replace(old,new,1),encoding="utf-8")
PY

node --check "$EXEC"
echo CANARY_SOURCE_RESOLUTION_OK

echo "=== 2. CENTRAL JOBS HEALTH ==="
curl -fsS --max-time 5 http://127.0.0.1:8091/api/health
echo

echo "=== 3. NATIVE CANARY RETEST ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá native-canary-2.txt con el texto CENTRAL_NATIVE_CANARY_2_OK, leelo y verificá que coincida exactamente.","source":"native-canary","project":"Central","conversation_id":"native-canary-2"}' \
  http://127.0.0.1:8091/api/jobs)
echo "$RESP"

JOB=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP")

for i in $(seq 1 180); do
  OUT=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB")
  S=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
  printf '\rstatus=%s elapsed=%ss' "$S" "$i"
  case "$S" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
echo
echo "$OUT"

OUT_JSON="$OUT" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
r=j.get("result") or {}
assert r.get("jugador")=="Central Native",r
assert r.get("native",{}).get("status")=="ok",r
assert "openclaw" not in r,r
assert "CENTRAL_STATUS=COMPLETADO" in r.get("resultado",""),r
print("CENTRAL_JOBS_NATIVE_CANARY_OK")
PY

FILE="/home/ubuntu/Central/work/$JOB/native-canary-2.txt"
test -f "$FILE"
grep -qx 'CENTRAL_NATIVE_CANARY_2_OK' "$FILE"
echo NATIVE_CANARY_FILE_OK

echo "=== 4. DIRECT REGRESSION ==="
RESP2=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá /tmp/native-direct-regression-2.txt con el texto DIRECT_2_OK y verificá","source":"chat","project":"Central","conversation_id":"native-direct-regression-2"}' \
  http://127.0.0.1:8091/api/jobs)
JOB2=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP2")
for i in $(seq 1 30); do
  OUT2=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB2")
  S2=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT2")
  case "$S2" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
OUT2_JSON="$OUT2" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT2_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
assert j.get("mode")=="DIRECT",j
print("DIRECT_REGRESSION_OK")
PY

echo CENTRAL_NATIVE_CANARY_ROUTE_FIXED
echo "backup=$BACKUP"
echo "NOTE=Canary only; normal FULL jobs still use legacy/OpenClaw."
