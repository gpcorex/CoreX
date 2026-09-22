#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STATE=/home/ubuntu/Central/state/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/context-tiers-v5-$STAMP

mkdir -p "$BACKUP"
for f in router.py cli.py providers.py BUILD_REPORT.json; do
  [ -e "$DEST/$f" ] && cp -a "$DEST/$f" "$BACKUP/$f"
done

echo "=== 1. SPLIT MODERATE CONTEXT FROM TRUE LONG CONTEXT ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/router.py")
s=p.read_text(encoding="utf-8")

s=s.replace(
'    "contexto_largo":"contexto_largo","long_context":"contexto_largo",\n',
'    "contexto_medio":"contexto_medio","moderate_context":"contexto_medio","retencion":"contexto_medio",\n'
'    "contexto_largo":"contexto_largo","long_context":"contexto_largo",\n'
)

s=s.replace(
'    "contexto_largo":["long_context"],\n',
'    "contexto_medio":["context_retention"],\n'
'    "contexto_largo":["long_context"],\n'
)

p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$DEST/router.py"
echo CONTEXT_TIERS_ROUTER_OK

echo "=== 2. UPDATE CLASSIFIER FOR CONTEXT TIERS ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/cli.py")
s=p.read_text(encoding="utf-8")

old='''    long_words=("contexto largo","documento enorme","archivo muy largo","muchos tokens","long context")
    structured_words=("json","salida estructurada","estructura exacta","schema","esquema json")
'''

new='''    true_long_words=("contexto largo","100k","128k","200k","256k","1m tokens","long context","archivo enorme","documento enorme")
    moderate_context_words=("documento largo","archivo largo","texto largo","retener contexto","muchas páginas","muchas paginas")
    structured_words=("json","salida estructurada","estructura exacta","schema","esquema json")
'''

if old not in s:
    raise SystemExit("CLASSIFIER_CONTEXT_ANCHOR_1_NOT_FOUND")
s=s.replace(old,new,1)

old2='''    if any(w in t for w in vision_words): return "vision"
    if any(w in t for w in voice_words): return "voz"
    if any(w in t for w in long_words): return "contexto_largo"
    if any(w in t for w in structured_words): return "estructurado"
'''

new2='''    if any(w in t for w in vision_words): return "vision"
    if any(w in t for w in voice_words): return "voz"
    if any(w in t for w in true_long_words): return "contexto_largo"
    if any(w in t for w in moderate_context_words): return "contexto_medio"
    if any(w in t for w in structured_words): return "estructurado"
'''

if old2 not in s:
    raise SystemExit("CLASSIFIER_CONTEXT_ANCHOR_2_NOT_FOUND")
s=s.replace(old2,new2,1)

p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$DEST/cli.py"
echo CONTEXT_TIERS_CLASSIFIER_OK

echo "=== 3. ADD CAPABILITY STATUS VIEW ==="
cat >"$DEST/capability_status.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import json
from config import load_settings
from providers import ProviderRegistry
from router import select, requirements_for

CAPS=[
    "programacion",
    "razonamiento",
    "conversacion",
    "estructurado",
    "contexto_medio",
    "contexto_largo",
    "vision",
    "voz",
]

def main():
    s=load_settings()
    r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
    report={}
    for cap in CAPS:
        req=requirements_for(cap)
        ranked=select(cap,r)
        verified=[]
        for item in ranked:
            caps=r.verified_capabilities(item["ref"])
            if not req or set(req).issubset(caps):
                verified.append(item["ref"])
        report[cap]={
            "requirements":req,
            "verified_routable":verified,
            "count":len(verified),
        }
    print(json.dumps(report,ensure_ascii=False,indent=2))

if __name__=="__main__":
    main()
PY
chmod 755 "$DEST/capability_status.py"
python3 -m py_compile "$DEST/capability_status.py"
echo CAPABILITY_STATUS_TOOL_OK

echo "=== 4. TEST CLASSIFICATION + ROUTING ==="
cat >"$DEST/tests/test_context_tiers_v5.py" <<'PY'
import unittest
from cli import infer_capability
from router import requirements_for

class ContextTierTests(unittest.TestCase):
    def test_moderate_context(self):
        self.assertEqual(infer_capability("Necesito revisar un documento largo y retener contexto","auto"),"contexto_medio")
    def test_true_long_context(self):
        self.assertEqual(infer_capability("Necesito contexto largo de 128k tokens","auto"),"contexto_largo")
    def test_requirements(self):
        self.assertEqual(requirements_for("contexto_medio"),["context_retention"])
        self.assertEqual(requirements_for("contexto_largo"),["long_context"])

if __name__=="__main__": unittest.main()
PY
PYTHONPATH="$DEST" python3 -m unittest discover -s "$DEST/tests" -p 'test_context_tiers_v5.py' -v
echo CONTEXT_TIERS_TESTS_OK

echo "=== 5. SHOW REAL CAPABILITY STATUS ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 "$DEST/capability_status.py" | tee /home/ubuntu/Central/state/capability-status.json

sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
import json
p="/home/ubuntu/Central/state/capability-status.json"
x=json.load(open(p,encoding="utf-8"))
assert x["programacion"]["count"]>=1,x
assert x["contexto_medio"]["count"]>=1,x
assert x["contexto_largo"]["count"]==0,x
print("CAPABILITY_STATUS_CONSISTENT_OK")
PY

echo "=== 6. LIVE MODERATE-CONTEXT ROUTING TEST ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Necesito trabajar con un documento largo. Creá contexto-medio.txt con el texto CONTEXTO_MEDIO_OK, leelo y verificá que coincida exactamente.","source":"chat","project":"Central","conversation_id":"context-tier-v5"}' \
  http://127.0.0.1:8091/api/jobs)
JOB=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP")
for i in $(seq 1 120); do
  OUT=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB")
  S=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
  printf '\rstatus=%s elapsed=%ss' "$S" "$i"
  case "$S" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
echo
OUT_JSON="$OUT" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
r=j.get("result") or {}
assert r.get("jugador")=="Central Native",r
print("CENTRAL_CONTEXT_TIER_REGRESSION_OK")
PY
grep -qx 'CONTEXTO_MEDIO_OK' "/home/ubuntu/Central/work/$JOB/contexto-medio.txt"

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "context-tiers-v5",
  "contexto_medio": "requires context_retention functional proof",
  "contexto_largo": "requires long_context proof and currently remains unverified",
  "capability_status_tool": true,
  "periodic_refresh": false,
  "active": true
}
EOF

echo CENTRAL_CONTEXT_TIERS_V5_READY
echo "status=/home/ubuntu/Central/state/capability-status.json"
echo "backup=$BACKUP"
