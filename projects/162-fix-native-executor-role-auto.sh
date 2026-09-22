#!/usr/bin/env bash
set -euo pipefail

RUNTIME=/home/ubuntu/Central/runtime
EXEC="$RUNTIME/native_executor.py"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-role-auto-fix-$STAMP

mkdir -p "$BACKUP"
cp -a "$EXEC" "$BACKUP/native_executor.py"

echo "=== 1. FIX NATIVE EXECUTOR ROLE OVERRIDE ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/runtime/native_executor.py")
s=p.read_text(encoding="utf-8")

old='''        "--role","tecnico",
'''
new='''        "--role","auto",
'''

if old not in s:
    raise SystemExit("ROLE_OVERRIDE_ANCHOR_NOT_FOUND")

p.write_text(s.replace(old,new,1),encoding="utf-8")
PY

python3 -m py_compile "$EXEC"
echo NATIVE_EXECUTOR_ROLE_AUTO_OK

echo "=== 2. LIVE PROGRAMMING CLASSIFICATION RETEST ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json'   -d '{"task":"Creá role-auto-fix.py que imprima exactamente ROLE_AUTO_FIX_OK, ejecutalo y verificá la salida.","source":"chat","project":"Central","conversation_id":"role-auto-fix"}'   http://127.0.0.1:8091/api/jobs)
echo "$RESP"
JOB=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP")

for i in $(seq 1 120); do
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
n=(j.get("result") or {}).get("native") or {}
assert n.get("status")=="ok",n
assert n.get("capability")=="programacion",n
assert n.get("model_ref"),n
assert isinstance(n.get("attempts"),list) and n["attempts"],n
print("LIVE_PROGRAMMING_CLASSIFICATION_OK")
print("capability="+str(n.get("capability")))
print("model_ref="+str(n.get("model_ref")))
print("router_score="+str(n.get("router_score")))
print("attempts="+str(len(n.get("attempts") or [])))
PY

grep -q 'ROLE_AUTO_FIX_OK' "/home/ubuntu/Central/work/$JOB/role-auto-fix.py"

echo "=== 3. LIVE CONVERSATION CLASSIFICATION RETEST ==="
RESP2=$(curl -fsS --max-time 5 -H 'Content-Type: application/json'   -d '{"task":"Decime brevemente qué significa hola.","source":"chat","project":"Central","conversation_id":"role-auto-conversation"}'   http://127.0.0.1:8091/api/jobs)
JOB2=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP2")
for i in $(seq 1 120); do
  OUT2=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB2")
  S2=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT2")
  printf '\rstatus=%s elapsed=%ss' "$S2" "$i"
  case "$S2" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
echo

OUT2_JSON="$OUT2" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT2_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
n=(j.get("result") or {}).get("native") or {}
assert n.get("capability")=="conversacion",n
print("LIVE_CONVERSATION_CLASSIFICATION_OK")
PY

echo CENTRAL_NATIVE_AUTO_CLASSIFICATION_READY
echo "backup=$BACKUP"
