#!/usr/bin/env bash
set -euo pipefail

NATIVE_EXEC=/home/ubuntu/Central/runtime/native_executor.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-task-contract-fix-$STAMP

mkdir -p "$BACKUP"
cp -a "$NATIVE_EXEC" "$BACKUP/native_executor.py"

echo "=== 1. PATCH NATIVE TASK EXTRACTION ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/runtime/native_executor.py")
s=p.read_text(encoding="utf-8")

old='''    trabajo=str(task.get("trabajo") or task.get("job_id") or task_path.parent.name)
    instruction=str(task.get("task") or task.get("orden") or task.get("pedido") or "").strip()
    if not instruction:
        raise SystemExit("EMPTY_TASK")
'''

new='''    trabajo=str(task.get("trabajo") or task.get("job_id") or task_path.parent.name)

    # Central's executor task.json is not the public Jobs API contract.
    # Resolve the instruction from all known executor shapes first.
    candidates=[
        task.get("task"),
        task.get("orden"),
        task.get("pedido"),
        task.get("instruction"),
        task.get("prompt"),
        task.get("objetivo"),
    ]
    contexto=task.get("contexto")
    if isinstance(contexto,dict):
        candidates.extend([
            contexto.get("task"),
            contexto.get("orden"),
            contexto.get("pedido"),
            contexto.get("instruction"),
            contexto.get("prompt"),
            contexto.get("objetivo"),
        ])

    instruction=next((str(x).strip() for x in candidates if x is not None and str(x).strip()),"")

    # Authoritative fallback: recover the original user task from Central Jobs.
    if not instruction and trabajo:
        job_path=Path("/home/ubuntu/Central/data/api-jobs")/trabajo/"job.json"
        if job_path.is_file():
            try:
                job=json.loads(job_path.read_text(encoding="utf-8"))
                instruction=str(job.get("task") or "").strip()
            except Exception:
                pass

    if not instruction:
        raise SystemExit("EMPTY_TASK")
'''

if old not in s:
    raise SystemExit("NATIVE_TASK_EXTRACTION_ANCHOR_NOT_FOUND")
p.write_text(s.replace(old,new,1),encoding="utf-8")
PY

python3 -m py_compile "$NATIVE_EXEC"
echo NATIVE_TASK_EXTRACTION_OK

echo "=== 2. SHOW FAILED JOB TASK SHAPE ==="
FAILED=TR-CENTRAL-20260922-170430-3f1ca6
if [ -f "/home/ubuntu/Central/data/api-jobs/$FAILED/task.json" ]; then
  python3 - "/home/ubuntu/Central/data/api-jobs/$FAILED/task.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8"))
print("task_json_keys=",sorted(x.keys()))
print("contexto_keys=",sorted((x.get("contexto") or {}).keys()) if isinstance(x.get("contexto"),dict) else [])
PY
fi

echo "=== 3. NATIVE CANARY RETEST ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá native-canary-3.txt con el texto CENTRAL_NATIVE_CANARY_3_OK, leelo y verificá que coincida exactamente.","source":"native-canary","project":"Central","conversation_id":"native-canary-3"}' \
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

FILE="/home/ubuntu/Central/work/$JOB/native-canary-3.txt"
test -f "$FILE"
grep -qx 'CENTRAL_NATIVE_CANARY_3_OK' "$FILE"
echo NATIVE_CANARY_FILE_OK

echo "=== 4. DIRECT REGRESSION ==="
RESP2=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá /tmp/native-direct-regression-3.txt con el texto DIRECT_3_OK y verificá","source":"chat","project":"Central","conversation_id":"native-direct-regression-3"}' \
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

echo CENTRAL_NATIVE_TASK_CONTRACT_FIXED
echo "backup=$BACKUP"
echo "NOTE=Canary only; normal FULL jobs still use legacy/OpenClaw."
