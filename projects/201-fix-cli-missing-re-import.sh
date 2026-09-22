#!/usr/bin/env bash
set -euo pipefail

CLI=/home/ubuntu/Central/native_v1/cli.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/classifier-file-create-v8-import-fix-$STAMP
mkdir -p "$BACKUP"
cp -a "$CLI" "$BACKUP/cli.py"

echo "=== 1. ADD MISSING RE IMPORT ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/cli.py")
s=p.read_text(encoding="utf-8")

lines=s.splitlines()
if not any(line.strip()=="import re" or line.strip().startswith("import re,") for line in lines):
    inserted=False
    for i,line in enumerate(lines):
        if line.startswith("import "):
            lines.insert(i,"import re")
            inserted=True
            break
    if not inserted:
        # after future import, if present
        idx=1 if lines and lines[0].startswith("from __future__") else 0
        lines.insert(idx,"import re")
    s="\n".join(lines)+"\n"
    p.write_text(s,encoding="utf-8")

PY

python3 -m py_compile "$CLI"
grep -n '^import re$' "$CLI"
echo CLI_RE_IMPORT_OK

echo "=== 2. CLASSIFIER TESTS ==="
PYTHONPATH=/home/ubuntu/Central/native_v1 python3 - <<'PY'
from cli import infer_capability
cases=[
("Creá preflight-canary.txt con el texto PREFLIGHT_CANARY_OK, leelo y verificá que coincida exactamente.","programacion"),
("Generá reporte.json con un resumen y guardalo.","programacion"),
("Editá config.yaml y cambiá el puerto.","programacion"),
("¿Qué es un archivo txt?","conversacion"),
("Contame qué significa preflight-canary.txt.","conversacion"),
]
for text,expected in cases:
    got=infer_capability(text,"auto")
    print(got,"::",text)
    assert got==expected,(text,got,expected)
print("FILE_CREATE_CLASSIFIER_TESTS_OK")
PY

echo "=== 3. LIVE JOB RETEST ==="
RESP=$(curl -fsS --max-time 10 -H 'Content-Type: application/json'   -d '{"task":"Creá classifier-v8b.txt con el texto CLASSIFIER_V8B_OK, leelo y verificá que coincida exactamente.","source":"chat","project":"Central","conversation_id":"classifier-v8b"}'   http://127.0.0.1:8091/api/jobs)
echo "$RESP"
JOB=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' <<<"$RESP")

for i in $(seq 1 120); do
  OUT=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB")
  STATUS=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
  printf '\rstatus=%s elapsed=%ss' "$STATUS" "$i"
  case "$STATUS" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
echo
echo "$OUT"

OUT_JSON="$OUT" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
n=(j.get("result") or {}).get("native") or {}
assert n.get("capability")=="programacion",n
assert n.get("model_ref"),n
print("FILE_CREATE_LIVE_CLASSIFICATION_OK")
print("model_ref="+str(n.get("model_ref")))
PY

grep -qx 'CLASSIFIER_V8B_OK' "/home/ubuntu/Central/work/$JOB/classifier-v8b.txt"
echo FILE_CREATE_CANARY_OK

echo CENTRAL_FILE_CREATE_CLASSIFIER_V8_FIXED_READY
echo "backup=$BACKUP"
