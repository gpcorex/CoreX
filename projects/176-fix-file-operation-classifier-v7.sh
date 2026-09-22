#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/classifier-files-v7-$STAMP

mkdir -p "$BACKUP"
cp -a "$DEST/cli.py" "$BACKUP/cli.py"
[ -f "$DEST/BUILD_REPORT.json" ] && cp -a "$DEST/BUILD_REPORT.json" "$BACKUP/BUILD_REPORT.json"

echo "=== 1. EXTEND CLASSIFIER FOR FILE-OPERATIVE TASKS ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/cli.py")
s=p.read_text(encoding="utf-8")

old='''    code_words=(
        "python","programa","código","codigo","script","bash","programar",
        "función","funcion","test",".py",".js",".sh",".ts",
        "ejecutá","ejecuta","ejecutalo","ejecutarlo","ejecutálo","ejecut",
        "compil","imprima","imprimir","stdout","returncode","comando"
    )
'''
new='''    code_words=(
        "python","programa","código","codigo","script","bash","programar",
        "función","funcion","test",".py",".js",".sh",".ts",
        "ejecutá","ejecuta","ejecutalo","ejecutarlo","ejecutálo","ejecut",
        "compil","imprima","imprimir","stdout","returncode","comando",
        "creá el archivo","crea el archivo","crear el archivo",
        "modificá el archivo","modifica el archivo","modificar el archivo",
        "editá el archivo","edita el archivo","editar el archivo",
        "copiando exactamente","copiar exactamente","guardá en","guardar en"
    )
    file_operation_words=(
        "archivo adjunto","adjunto original","workspace","leer el archivo",
        "leé el archivo","lee el archivo","copiá el archivo","copia el archivo",
        "copiar el archivo","renombrá el archivo","renombra el archivo",
        "mover el archivo","mové el archivo","editar archivo","modificar archivo"
    )
'''
if old not in s:
    raise SystemExit("CLASSIFIER_CODE_WORDS_BLOCK_NOT_FOUND")
s=s.replace(old,new,1)

old2='''    if any(w in t for w in structured_words): return "estructurado"
    if any(w in t for w in code_words): return "programacion"
'''
new2='''    if any(w in t for w in structured_words): return "estructurado"
    if any(w in t for w in file_operation_words) and any(v in t for v in ("creá","crea","crear","copi","modific","edit","mov","guard","gener")):
        return "programacion"
    if any(w in t for w in code_words): return "programacion"
'''
if old2 not in s:
    raise SystemExit("CLASSIFIER_DECISION_ANCHOR_NOT_FOUND")
s=s.replace(old2,new2,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$DEST/cli.py"
echo FILE_OPERATION_CLASSIFIER_PATCH_OK

echo "=== 2. ADD REGRESSION TESTS ==="
cat >"$DEST/tests/test_classifier_files_v7.py" <<'PY'
import unittest
from cli import infer_capability

class FileOperationClassifierV7(unittest.TestCase):
    def test_attachment_copy_task_is_programming(self):
        text="Creá el archivo resultado-adjunto.txt leyendo el archivo adjunto original y copiando exactamente su contenido. Después verificá que coincida."
        self.assertEqual(infer_capability(text,"auto"),"programacion")

    def test_attachment_question_stays_conversation(self):
        text="¿Qué dice el archivo adjunto?"
        self.assertEqual(infer_capability(text,"auto"),"conversacion")

    def test_image_question_stays_vision(self):
        text="¿Qué ves en esta imagen?"
        self.assertEqual(infer_capability(text,"auto"),"vision")

if __name__=="__main__": unittest.main()
PY

PYTHONPATH="$DEST" python3 -m unittest discover -s "$DEST/tests" -p 'test_classifier_files_v7.py' -v
echo FILE_OPERATION_CLASSIFIER_TESTS_OK

echo "=== 3. LIVE OPERATIONAL ATTACHMENT CLASSIFICATION TEST ==="
SRC=/tmp/classifier-file-op.txt
printf 'FILE_CLASSIFIER_731\n' > "$SRC"

REQ=/tmp/classifier-file-upload.json
python3 - "$SRC" "$REQ" <<'PY'
import base64,json,sys
src,dst=sys.argv[1:]
with open(src,"rb") as f:b64=base64.b64encode(f.read()).decode()
with open(dst,"w",encoding="utf-8") as f:
    json.dump({"name":"clasificador.txt","mime":"text/plain","data_base64":b64},f,separators=(",",":"))
PY

UP=$(curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @"$REQ" http://127.0.0.1:8791/api/attachments)
CID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["conversation_id"])' <<<"$UP")
AID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["attachment"]["id"])' <<<"$UP")

MSGREQ=/tmp/classifier-file-message.json
python3 - "$CID" "$AID" "$MSGREQ" <<'PY'
import json,sys
cid,aid,dst=sys.argv[1:]
with open(dst,"w",encoding="utf-8") as f:
    json.dump({
      "conversation_id":cid,
      "text":"Creá el archivo salida-clasificada.txt leyendo el archivo adjunto original y copiando exactamente su contenido. Después verificá que coincida.",
      "attachment_ids":[aid]
    },f,ensure_ascii=False)
PY

MSG=$(curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @"$MSGREQ" http://127.0.0.1:8791/api/message)
echo "$MSG"
JOB=$(MSG_JSON="$MSG" python3 - <<'PY'
import json,os
x=json.loads(os.environ["MSG_JSON"])
assert x["ok"] is True,x
assert x["mode"]=="job",x
print(x["job_id"])
PY
)

for i in $(seq 1 120); do
  OUT=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB")
  STATUS=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
  printf '\rstatus=%s elapsed=%ss' "$STATUS" "$i"
  case "$STATUS" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
echo

OUT_JSON="$OUT" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
n=(j.get("result") or {}).get("native") or {}
assert n.get("capability")=="programacion",n
assert n.get("model_ref"),n
print("LIVE_FILE_OPERATION_CLASSIFICATION_OK")
print("capability="+n["capability"])
print("model_ref="+n["model_ref"])
PY

test -f "/home/ubuntu/Central/work/$JOB/salida-clasificada.txt"
grep -qx 'FILE_CLASSIFIER_731' "/home/ubuntu/Central/work/$JOB/salida-clasificada.txt"

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "classifier-files-v7",
  "file_operations_classified_as_programming": true,
  "attachment_questions_remain_non_operational": true,
  "active": true
}
EOF

echo CENTRAL_FILE_OPERATION_CLASSIFIER_V7_READY
echo "backup=$BACKUP"
