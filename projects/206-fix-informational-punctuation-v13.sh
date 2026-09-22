#!/usr/bin/env bash
set -euo pipefail

CLI=/home/ubuntu/Central/native_v1/cli.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/classifier-info-punctuation-v13-$STAMP
mkdir -p "$BACKUP"
cp -a "$CLI" "$BACKUP/cli.py"

echo "=== 1. NORMALIZE LEADING QUESTION PUNCTUATION IN CLASSIFIER ==="
python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Central/native_v1/cli.py")
s=p.read_text(encoding="utf-8")

old='''    if any(t.strip().startswith(x) for x in informational_prefixes):
        return "conversacion"
'''
new='''    normalized_t=t.strip().lstrip("¿?¡! ").strip()
    if any(normalized_t.startswith(x) for x in informational_prefixes):
        return "conversacion"
'''

if old not in s:
    raise SystemExit("INFORMATIONAL_GUARD_ANCHOR_NOT_FOUND")

p.write_text(s.replace(old,new,1),encoding="utf-8")
PY

python3 -m py_compile "$CLI"
echo CLASSIFIER_INFO_PUNCTUATION_PATCH_OK

echo "=== 2. CLASSIFIER REGRESSION TESTS ==="
PYTHONPATH=/home/ubuntu/Central/native_v1 python3 - <<'PY'
from cli import infer_capability

cases=[
    ("Creá preflight-canary.txt con el texto PREFLIGHT_CANARY_OK, leelo y verificá que coincida exactamente.","programacion"),
    ("Generá reporte.json con un resumen y guardalo.","programacion"),
    ("Editá config.yaml y cambiá el puerto.","programacion"),
    ("Creá datos.csv con dos filas.","programacion"),
    ("Guardá config.json con esos valores.","programacion"),
    ("Dame una respuesta en JSON con nombre y edad.","estructurado"),
    ("Respondé solamente con JSON válido.","estructurado"),
    ("Mostrame un ejemplo de reporte.json.","conversacion"),
    ("Dame un ejemplo de config.yaml.","conversacion"),
    ("¿Qué es un archivo txt?","conversacion"),
    ("¿Qué significa reporte.json?","conversacion"),
    ("¡Explicame cómo funciona config.yaml!","conversacion"),
]
for text,expected in cases:
    got=infer_capability(text,"auto")
    print(got,"::",text)
    assert got==expected,(text,got,expected)

print("CLASSIFIER_INFO_PUNCTUATION_V13_TESTS_OK")
PY

echo "=== 3. LIVE FILE JOB RETEST ==="
RESP=$(curl -fsS --max-time 10 -H 'Content-Type: application/json'   -d '{"task":"Generá classifier-v13.json con el contenido exacto {\"ok\":true}, leelo y verificá que coincida exactamente.","source":"chat","project":"Central","conversation_id":"classifier-v13"}'   http://127.0.0.1:8091/api/jobs)
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

test -f "/home/ubuntu/Central/work/$JOB/classifier-v13.json"
python3 - "$JOB" <<'PY'
import json,sys
p=f"/home/ubuntu/Central/work/{sys.argv[1]}/classifier-v13.json"
x=json.load(open(p,encoding="utf-8"))
assert x=={"ok":True},x
print("FILE_CREATE_JSON_CONTENT_OK")
PY

echo CENTRAL_CLASSIFIER_INFO_PUNCTUATION_V13_READY
echo "backup=$BACKUP"
