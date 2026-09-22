#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Interfaz/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/operational-intent-v4-$STAMP
mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. NORMALIZE LEADING QUESTION PUNCTUATION ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

old='''def is_operational(text:str)->bool:
    raw=text.lower().strip()
    # Purely explanatory questions must stay in chat even if they mention
    # operational nouns such as snapshot, Central Jobs, Router, etc.
    if any(raw.startswith(p) for p in INFO_QUERY_PREFIXES):
        return False
    t=" "+raw+" "
    if any(p in t for p in STRONG_OPERATIONAL_PATTERNS):
        return True
    return any(w in t for w in ACTION_WORDS) and any(w in t for w in TECH_WORDS)
'''

new='''def is_operational(text:str)->bool:
    raw=text.lower().strip()
    normalized=raw.lstrip("¿?¡! ").strip()
    # Purely explanatory questions must stay in chat even if they mention
    # operational nouns such as snapshot, Central Jobs, Router, etc.
    if any(normalized.startswith(p) for p in INFO_QUERY_PREFIXES):
        return False
    t=" "+normalized+" "
    if any(p in t for p in STRONG_OPERATIONAL_PATTERNS):
        return True
    return any(w in t for w in ACTION_WORDS) and any(w in t for w in TECH_WORDS)
'''

if old not in s:
    raise SystemExit("IS_OPERATIONAL_V3_BLOCK_NOT_FOUND")

p.write_text(s.replace(old,new,1),encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo OPERATIONAL_INTENT_V4_PATCH_OK

echo "=== 2. CLASSIFIER TESTS ==="
python3 - <<'PY'
import importlib.util
spec=importlib.util.spec_from_file_location("interfaz","/home/ubuntu/Interfaz/server.py")
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

cases=[
("Ejecutá una auditoría completa del estado actual de Central y generá un snapshot canónico.",True),
("Auditá Central completo y dejame el estado canónico.",True),
("Revisá los servicios y verificá que el puerto esté cerrado.",True),
("Generá un snapshot canónico de Central.",True),
("¿Qué es un snapshot canónico?",False),
("Que es un snapshot canonico?",False),
("¿Cómo funciona Central Jobs?",False),
("Contame cómo funciona Router/Providers.",False),
("Para qué sirve una auditoría de Central?",False),
("¡Explicame qué hace Central Jobs!",False),
("Hola",False),
]
for text,expected in cases:
    got=m.is_operational(text)
    print(("JOB" if got else "CHAT")+" :: "+text)
    assert got is expected,(text,got,expected)

print("OPERATIONAL_INTENT_V4_TESTS_OK")
PY

echo "=== 3. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/op-intent-v4-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/op-intent-v4-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_OPERATIONAL_INTENT_V4_SERVICE_OK

echo "=== 4. LIVE CHAT/OPERATION ROUTING TESTS ==="
Q1=$(curl -fsS --max-time 120 -H 'Content-Type: application/json'   -d '{"text":"¿Qué es un snapshot canónico?"}'   http://127.0.0.1:8791/api/message)
echo "$Q1"
Q1_JSON="$Q1" python3 - <<'PY'
import json,os
x=json.loads(os.environ["Q1_JSON"])
assert x["ok"] is True,x
assert x["mode"]=="chat",x
print("INFO_QUESTION_STAYS_CHAT_OK")
PY

Q2=$(curl -fsS --max-time 30 -H 'Content-Type: application/json'   -d '{"text":"Auditá Central completo y generá un snapshot canónico del estado."}'   http://127.0.0.1:8791/api/message)
echo "$Q2"
Q2_JSON="$Q2" python3 - <<'PY'
import json,os
x=json.loads(os.environ["Q2_JSON"])
assert x["ok"] is True,x
assert x["mode"]=="job",x
print("AUDIT_COMMAND_ROUTES_TO_JOB_OK")
print("job_id="+x["job_id"])
PY

echo CENTRAL_OPERATIONAL_INTENT_V4_READY
echo "backup=$BACKUP"
