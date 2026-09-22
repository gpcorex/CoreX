#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Interfaz/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/operational-intent-v5-$STAMP
mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. EXPAND INFORMATIONAL QUESTION PREFIXES ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

old='''INFO_QUERY_PREFIXES = (
    "qué es ","que es ","qué son ","que son ",
    "cómo funciona ","como funciona ","cómo se ","como se ",
    "para qué sirve ","para que sirve ","explicame ","explicáme ",
    "contame ","decime qué ","decime que "
)
'''

new='''INFO_QUERY_PREFIXES = (
    "qué es ","que es ","qué son ","que son ",
    "qué significa ","que significa ","qué quiere decir ","que quiere decir ",
    "qué entendemos por ","que entendemos por ",
    "cómo funciona ","como funciona ","cómo se ","como se ",
    "para qué sirve ","para que sirve ","explicame ","explicáme ",
    "contame ","decime qué ","decime que "
)
'''

if old not in s:
    raise SystemExit("INFO_QUERY_PREFIXES_ANCHOR_NOT_FOUND")

p.write_text(s.replace(old,new,1),encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo OPERATIONAL_INTENT_V5_PATCH_OK

echo "=== 2. CLASSIFIER TESTS ==="
python3 - <<'PY'
import importlib.util
spec=importlib.util.spec_from_file_location("interfaz","/home/ubuntu/Interfaz/server.py")
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

cases=[
("¿Qué significa estado canónico en Central?",False),
("Que significa estado canonico en Central?",False),
("¿Qué quiere decir estado canónico?",False),
("¿Qué entendemos por estado canónico?",False),
("¿Qué es un snapshot canónico?",False),
("¿Cómo funciona Central Jobs?",False),
("Auditá Central completo y generá un snapshot canónico del estado.",True),
("Ejecutá una auditoría completa de Central.",True),
]
for text,expected in cases:
    got=m.is_operational(text)
    print(("JOB" if got else "CHAT")+" :: "+text)
    assert got is expected,(text,got,expected)

print("OPERATIONAL_INTENT_V5_TESTS_OK")
PY

echo "=== 3. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/op-intent-v5-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/op-intent-v5-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_OPERATIONAL_INTENT_V5_SERVICE_OK

echo "=== 4. LIVE TEST EXACT USER PHRASE ==="
Q1=$(curl -fsS --max-time 120 -H 'Content-Type: application/json'   -d '{"text":"¿Qué significa estado canónico en Central?"}'   http://127.0.0.1:8791/api/message)
echo "$Q1"
Q1_JSON="$Q1" python3 - <<'PY'
import json,os
x=json.loads(os.environ["Q1_JSON"])
assert x["ok"] is True,x
assert x["mode"]=="chat",x
a=x.get("answer","").lower()
assert any(k in a for k in ("estado oficial","referencia oficial","arquitectura","configuración","configuracion")),a
print("EXACT_CANONICAL_QUESTION_STAYS_CHAT_OK")
PY

echo "=== 5. LIVE TEST AUDIT COMMAND ==="
Q2=$(curl -fsS --max-time 30 -H 'Content-Type: application/json'   -d '{"text":"Auditá Central completo y generá un snapshot canónico del estado."}'   http://127.0.0.1:8791/api/message)
echo "$Q2"
Q2_JSON="$Q2" python3 - <<'PY'
import json,os
x=json.loads(os.environ["Q2_JSON"])
assert x["ok"] is True,x
assert x["mode"]=="job",x
print("AUDIT_COMMAND_STILL_ROUTES_TO_JOB_OK")
print("job_id="+x["job_id"])
PY

echo CENTRAL_OPERATIONAL_INTENT_V5_READY
echo "backup=$BACKUP"
