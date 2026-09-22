#!/usr/bin/env bash
set -euo pipefail
SERVER=/home/ubuntu/Interfaz/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/operational-intent-v2-$STAMP
mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

s=s.replace(
'''    "programá","programa ","programar ","implementá","implementa ","implementar "
)''',
'''    "programá","programa ","programar ","implementá","implementa ","implementar ",
    "ejecutá","ejecuta ","ejecutar ","corré","corre ","correr ",
    "auditá","audita ","auditar ","revisá","revisa ","revisar ",
    "verificá","verifica ","verificar ","validá","valida ","validar ",
    "diagnosticá","diagnostica ","diagnosticar ","inspeccioná","inspecciona ","inspeccionar ",
    "comprobá","comprueba ","comprobar ","generá","genera ","generar "
)''',1)

s=s.replace(
'''    "base de datos","sqlite","puerto","script","interfaz","código","codigo","proyecto"
)''',
'''    "base de datos","sqlite","puerto","script","interfaz","código","codigo","proyecto",
    "router","provider","providers","job","jobs","snapshot","estado canónico","estado canonico",
    "auditoría","auditoria","diagnóstico","diagnostico","workspace","pwa","manifest",
    "service worker","proceso","procesos","logs","log","health","salud"
)''',1)

old='''def is_operational(text:str)->bool:
    t=" "+text.lower().strip()+" "
    return any(w in t for w in ACTION_WORDS) and any(w in t for w in TECH_WORDS)
'''
new='''STRONG_OPERATIONAL_PATTERNS = (
    "auditoría completa","auditoria completa","estado canónico","estado canonico",
    "snapshot canónico","snapshot canonico","ejecutá una auditoría","ejecuta una auditoria",
    "generá un snapshot","genera un snapshot","diagnosticá central","diagnostica central"
)

def is_operational(text:str)->bool:
    t=" "+text.lower().strip()+" "
    if any(p in t for p in STRONG_OPERATIONAL_PATTERNS):
        return True
    return any(w in t for w in ACTION_WORDS) and any(w in t for w in TECH_WORDS)
'''
if old not in s:
    raise SystemExit("IS_OPERATIONAL_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"

python3 - <<'PY'
import importlib.util
spec=importlib.util.spec_from_file_location("interfaz","/home/ubuntu/Interfaz/server.py")
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cases=[
("Ejecutá una auditoría completa del estado actual de Central y generá un snapshot canónico.",True),
("Auditá Central completo y dejame el estado canónico.",True),
("¿Qué es un snapshot canónico?",False),
("Contame cómo funciona Central Jobs.",False),
("Hola",False),
]
for text,expected in cases:
    got=m.is_operational(text)
    assert got is expected,(text,got,expected)
print("OPERATIONAL_INTENT_UNIT_TESTS_OK")
PY

sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/op-intent-v2-health.json 2>/dev/null && break
  sleep 1
done
cat /tmp/op-intent-v2-health.json
echo
echo CENTRAL_OPERATIONAL_INTENT_V2_READY
echo "backup=$BACKUP"
