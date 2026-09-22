#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/classifier-v6-fix-$STAMP

mkdir -p "$BACKUP"
cp -a "$DEST/cli.py" "$BACKUP/cli.py"
[ -f "$DEST/BUILD_REPORT.json" ] && cp -a "$DEST/BUILD_REPORT.json" "$BACKUP/BUILD_REPORT.json"

echo "=== 1. FIX PROGRAMMING CLASSIFICATION ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/cli.py")
s=p.read_text(encoding="utf-8")

old='''    code_words=("python","programa","código","codigo","script","bash","programar","función","funcion","test","archivo")
'''
new='''    code_words=(
        "python","programa","código","codigo","script","bash","programar",
        "función","funcion","test",".py",".js",".sh",".ts",
        "ejecutá","ejecuta","ejecutalo","ejecutarlo","ejecutálo","ejecut",
        "compil","imprima","imprimir","stdout","returncode","comando"
    )
'''
if old not in s:
    raise SystemExit("CLASSIFIER_CODE_WORDS_ANCHOR_NOT_FOUND")
p.write_text(s.replace(old,new,1),encoding="utf-8")
PY

python3 -m py_compile "$DEST/cli.py"
echo CLASSIFIER_PROGRAMMING_SIGNALS_OK

echo "=== 2. CLASSIFIER REGRESSION TESTS ==="
cat >"$DEST/tests/test_classifier_v6.py" <<'PY'
import unittest
from cli import infer_capability

class ClassifierV6Tests(unittest.TestCase):
    def test_py_file_execution_is_programming(self):
        text="Creá routing-evidence.py que imprima exactamente ROUTING_EVIDENCE_OK, ejecutalo y verificá la salida."
        self.assertEqual(infer_capability(text,"auto"),"programacion")

    def test_plain_conversation_stays_conversation(self):
        self.assertEqual(infer_capability("Hola, cómo estás","auto"),"conversacion")

    def test_json_output_is_structured(self):
        self.assertEqual(infer_capability("Respondé en JSON con este schema","auto"),"estructurado")

    def test_analysis_is_reasoning(self):
        self.assertEqual(infer_capability("Analizá estas alternativas","auto"),"razonamiento")

if __name__=="__main__": unittest.main()
PY

PYTHONPATH="$DEST" python3 -m unittest discover -s "$DEST/tests" -p 'test_classifier_v6.py' -v
echo CLASSIFIER_V6_TESTS_OK

echo "=== 3. LIVE ROUTER EVIDENCE RETEST ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json'   -d '{"task":"Creá routing-evidence-v6.py que imprima exactamente ROUTING_EVIDENCE_V6_OK, ejecutalo y verificá la salida.","source":"chat","project":"Central","conversation_id":"routing-evidence-v6-fix"}'   http://127.0.0.1:8091/api/jobs)
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
assert n["attempts"][-1].get("ok") is True,n
print("ROUTER_EVIDENCE_PROGRAMMING_OK")
print("capability="+str(n.get("capability")))
print("model_ref="+str(n.get("model_ref")))
print("router_score="+str(n.get("router_score")))
print("attempts="+str(len(n.get("attempts") or [])))
PY

grep -q 'ROUTING_EVIDENCE_V6_OK' "/home/ubuntu/Central/work/$JOB/routing-evidence-v6.py"

echo "=== 4. DIRECT REGRESSION ==="
RESP2=$(curl -fsS --max-time 5 -H 'Content-Type: application/json'   -d '{"task":"Creá /tmp/classifier-v6-direct.txt con el texto CLASSIFIER_DIRECT_OK y verificá","source":"chat","project":"Central","conversation_id":"classifier-v6-direct"}'   http://127.0.0.1:8091/api/jobs)
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

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "classifier-v6-fix",
  "programming_detection_extended": true,
  "router_evidence_in_job_result": true,
  "active": true
}
EOF

echo CENTRAL_CLASSIFIER_V6_READY
echo "backup=$BACKUP"
