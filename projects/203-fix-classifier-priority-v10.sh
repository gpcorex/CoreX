#!/usr/bin/env bash
set -euo pipefail

CLI=/home/ubuntu/Central/native_v1/cli.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/classifier-priority-v10-$STAMP
mkdir -p "$BACKUP"
cp -a "$CLI" "$BACKUP/cli.py"

echo "=== 1. REORDER CLASSIFIER DECISIONS STRUCTURALLY ==="
python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Central/native_v1/cli.py")
lines=p.read_text(encoding="utf-8").splitlines()

structured_idx=next((i for i,x in enumerate(lines) if 'structured_words' in x and 'return "estructurado"' in x),None)
fileop_idx=next((i for i,x in enumerate(lines) if 'file_operation_words' in x and 'file_action_words' in x),None)

if structured_idx is None:
    raise SystemExit("STRUCTURED_DECISION_NOT_FOUND")
if fileop_idx is None:
    raise SystemExit("FILE_OPERATION_DECISION_NOT_FOUND")

print("before_structured_line=",structured_idx+1)
print("before_fileop_line=",fileop_idx+1)

if structured_idx < fileop_idx:
    structured_line=lines.pop(structured_idx)
    fileop_idx=next(i for i,x in enumerate(lines) if 'file_operation_words' in x and 'file_action_words' in x)
    lines.insert(fileop_idx,structured_line)

p.write_text("\n".join(lines)+"\n",encoding="utf-8")
PY

python3 -m py_compile "$CLI"
echo CLASSIFIER_PRIORITY_V10_PATCH_OK

echo "=== 2. SHOW DECISION ORDER ==="
grep -nE 'structured_words.*return|file_operation_words.*file_action_words|re\.search.*txt\|md\|json' "$CLI" || true

echo "=== 3. CLASSIFIER REGRESSION TESTS ==="
PYTHONPATH=/home/ubuntu/Central/native_v1 python3 - <<'PY'
from cli import infer_capability

cases=[
    ("Creá preflight-canary.txt con el texto PREFLIGHT_CANARY_OK, leelo y verificá que coincida exactamente.","programacion"),
    ("Generá reporte.json con un resumen y guardalo.","programacion"),
    ("Editá config.yaml y cambiá el puerto.","programacion"),
    ("Creá datos.csv con dos filas.","programacion"),
    ("Dame una respuesta en JSON con nombre y edad.","estructurado"),
    ("Respondé solamente con JSON válido.","estructurado"),
    ("¿Qué es un archivo txt?","conversacion"),
    ("Contame qué significa preflight-canary.txt.","conversacion"),
]
for text,expected in cases:
    got=infer_capability(text,"auto")
    print(got,"::",text)
    assert got==expected,(text,got,expected)

print("CLASSIFIER_PRIORITY_V10_TESTS_OK")
PY

echo "=== 4. LIVE JSON-FILE JOB ==="
RESP=$(curl -fsS --max-time 10 -H 'Content-Type: application/json'   -d '{"task":"Generá classifier-v10.json con el contenido exacto {\"ok\":true}, leelo y verificá que coincida exactamente.","source":"chat","project":"Central","conversation_id":"classifier-v10"}'   http://127.0.0.1:8091/api/jobs)
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
print("FILE_CREATE_JSON_LIVE_CLASSIFICATION_OK")
print("model_ref="+str(n.get("model_ref")))
PY

test -f "/home/ubuntu/Central/work/$JOB/classifier-v10.json"
python3 - "$JOB" <<'PY'
import json,sys
p=f"/home/ubuntu/Central/work/{sys.argv[1]}/classifier-v10.json"
x=json.load(open(p,encoding="utf-8"))
assert x=={"ok":True},x
print("FILE_CREATE_JSON_CONTENT_OK")
PY

echo CENTRAL_CLASSIFIER_PRIORITY_V10_READY
echo "backup=$BACKUP"
