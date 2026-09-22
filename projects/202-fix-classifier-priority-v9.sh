#!/usr/bin/env bash
set -euo pipefail

CLI=/home/ubuntu/Central/native_v1/cli.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/classifier-priority-v9-$STAMP
mkdir -p "$BACKUP"
cp -a "$CLI" "$BACKUP/cli.py"

echo "=== 1. FIX CLASSIFIER PRIORITY: FILE ACTION BEFORE STRUCTURED ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/cli.py")
s=p.read_text(encoding="utf-8")

old='''    if any(w in t for w in structured_words): return "estructurado"
    if any(w in t for w in file_operation_words) and any(v in t for v in file_action_words):
        return "programacion"
    if any(v in t for v in file_action_words) and re.search(r'\b[\w.-]+\.(?:txt|md|json|csv|py|js|ts|sh|log|yaml|yml|xml|html|css|ini|conf)\b', t):
        return "programacion"
    if any(w in t for w in code_words): return "programacion"
'''

new='''    # Explicit file mutations take precedence over content-format hints.
    # Example: "Generá reporte.json..." is a programming/file operation,
    # not merely a request for structured output.
    if any(w in t for w in file_operation_words) and any(v in t for v in file_action_words):
        return "programacion"
    if any(v in t for v in file_action_words) and re.search(r'\b[\w.-]+\.(?:txt|md|json|csv|py|js|ts|sh|log|yaml|yml|xml|html|css|ini|conf)\b', t):
        return "programacion"
    if any(w in t for w in structured_words): return "estructurado"
    if any(w in t for w in code_words): return "programacion"
'''

if old not in s:
    raise SystemExit("CLASSIFIER_PRIORITY_BLOCK_NOT_FOUND")

p.write_text(s.replace(old,new,1),encoding="utf-8")
PY

python3 -m py_compile "$CLI"
echo CLASSIFIER_PRIORITY_PATCH_OK

echo "=== 2. CLASSIFIER REGRESSION TESTS ==="
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
print("CLASSIFIER_PRIORITY_V9_TESTS_OK")
PY

echo "=== 3. LIVE FILE-CREATION JOB ==="
RESP=$(curl -fsS --max-time 10 -H 'Content-Type: application/json'   -d '{"task":"Generá classifier-v9.json con el contenido exacto {\"ok\":true}, leelo y verificá que coincida exactamente.","source":"chat","project":"Central","conversation_id":"classifier-v9"}'   http://127.0.0.1:8091/api/jobs)
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

test -f "/home/ubuntu/Central/work/$JOB/classifier-v9.json"
python3 - "$JOB" <<'PY'
import json,sys
p=f"/home/ubuntu/Central/work/{sys.argv[1]}/classifier-v9.json"
x=json.load(open(p,encoding="utf-8"))
assert x=={"ok":True},x
print("FILE_CREATE_JSON_CONTENT_OK")
PY

echo CENTRAL_CLASSIFIER_PRIORITY_V9_READY
echo "backup=$BACKUP"
