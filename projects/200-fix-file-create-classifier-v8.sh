#!/usr/bin/env bash
set -euo pipefail

CLI=/home/ubuntu/Central/native_v1/cli.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/classifier-file-create-v8-$STAMP
mkdir -p "$BACKUP"
cp -a "$CLI" "$BACKUP/cli.py"

echo "=== 1. FIX FILE-CREATION CLASSIFICATION ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/cli.py")
s=p.read_text(encoding="utf-8")

old='''    file_operation_words=(
        "archivo adjunto","adjunto original","workspace","leer el archivo",
        "leé el archivo","lee el archivo","copiá el archivo","copia el archivo",
        "copiar el archivo","renombrá el archivo","renombra el archivo",
        "mover el archivo","mové el archivo","editar archivo","modificar archivo"
    )
'''
new='''    file_operation_words=(
        "archivo adjunto","adjunto original","workspace","leer el archivo",
        "leé el archivo","lee el archivo","copiá el archivo","copia el archivo",
        "copiar el archivo","renombrá el archivo","renombra el archivo",
        "mover el archivo","mové el archivo","editar archivo","modificar archivo"
    )
    file_action_words=(
        "creá","crea","crear","generá","genera","generar","guardá","guarda","guardar",
        "escribí","escribe","escribir","modificá","modifica","modificar",
        "editá","edita","editar","copiá","copia","copiar","renombrá","renombra","renombrar",
        "mové","mueve","mover","borrá","borra","borrar","eliminá","elimina","eliminar"
    )
'''
if 'file_action_words=(' not in s:
    if old not in s:
        raise SystemExit("FILE_OPERATION_WORDS_ANCHOR_NOT_FOUND")
    s=s.replace(old,new,1)

old2='''    if any(w in t for w in structured_words): return "estructurado"
    if any(w in t for w in file_operation_words) and any(v in t for v in ("creá","crea","crear","copi","modific","edit","mov","guard","gener")):
        return "programacion"
    if any(w in t for w in code_words): return "programacion"
'''
new2='''    if any(w in t for w in structured_words): return "estructurado"
    if any(w in t for w in file_operation_words) and any(v in t for v in file_action_words):
        return "programacion"
    if any(v in t for v in file_action_words) and re.search(r'\\b[\\w.-]+\\.(?:txt|md|json|csv|py|js|ts|sh|log|yaml|yml|xml|html|css|ini|conf)\\b', t):
        return "programacion"
    if any(w in t for w in code_words): return "programacion"
'''
if old2 not in s:
    raise SystemExit("CLASSIFIER_DECISION_ANCHOR_NOT_FOUND")
s=s.replace(old2,new2,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$CLI"
echo FILE_CREATE_CLASSIFIER_PATCH_OK

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
RESP=$(curl -fsS --max-time 10 -H 'Content-Type: application/json'   -d '{"task":"Creá classifier-v8.txt con el texto CLASSIFIER_V8_OK, leelo y verificá que coincida exactamente.","source":"chat","project":"Central","conversation_id":"classifier-v8"}'   http://127.0.0.1:8091/api/jobs)
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

grep -qx 'CLASSIFIER_V8_OK' "/home/ubuntu/Central/work/$JOB/classifier-v8.txt"
echo FILE_CREATE_CANARY_OK

echo CENTRAL_FILE_CREATE_CLASSIFIER_V8_READY
echo "backup=$BACKUP"
