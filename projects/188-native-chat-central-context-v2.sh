#!/usr/bin/env bash
set -euo pipefail

CHAT=/home/ubuntu/Central/native_v1/native_chat.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-chat-central-context-$STAMP
mkdir -p "$BACKUP"
cp -a "$CHAT" "$BACKUP/native_chat.py"

echo "=== 1. ADD CENTRAL DOMAIN CONTEXT TO NATIVE CHAT ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/native_chat.py")
s=p.read_text(encoding="utf-8")

old='''SYSTEM=(
    "Sos la capa conversacional de Central. Respondé en español claro y natural. "
    "Mantené continuidad con el historial. No afirmes haber ejecutado cambios en la VM "
    "si no fueron realizados por Central Jobs. Si el usuario sólo conversa o pregunta, "
    "respondé directamente."
)
'''

new='''SYSTEM=(
    "Sos la capa conversacional de Central. Respondé en español claro y natural. "
    "Mantené continuidad con el historial. No afirmes haber ejecutado cambios en la VM "
    "si no fueron realizados por Central Jobs. Si el usuario sólo conversa o pregunta, "
    "respondé directamente. "
    "Contexto propio de este sistema: 'Central' es la plataforma del usuario que corre en su VM. "
    "Cuando el usuario diga 'estado canónico' o 'snapshot canónico' en contexto de Central, "
    "se refiere al estado oficial/documentado actual de la arquitectura, servicios, rutas, "
    "componentes, capacidades y configuración relevante de Central; no a un snapshot de disco, "
    "backup de VM ni imagen de infraestructura, salvo que lo aclare explícitamente. "
    "No inventes equipos humanos, tickets, departamentos ni procesos externos que no existan "
    "en el sistema. Si una acción requiere ejecución real, explicá que debe ir por Central Jobs."
)
'''

if old not in s:
    raise SystemExit("NATIVE_CHAT_SYSTEM_ANCHOR_NOT_FOUND")

p.write_text(s.replace(old,new,1),encoding="utf-8")
PY

python3 -m py_compile "$CHAT"
echo CENTRAL_CHAT_CONTEXT_PATCH_OK

echo "=== 2. DIRECT CONTEXT TEST ==="
REQ=/tmp/native-chat-central-context.json
cat >"$REQ" <<'JSON'
{"messages":[{"role":"user","content":"¿Qué significa estado canónico en Central?"}]}
JSON

OUT=$(sudo -u ubuntu env PYTHONPATH=/home/ubuntu/Central/native_v1 /usr/bin/python3 "$CHAT" < "$REQ")
echo "$OUT"
OUT_JSON="$OUT" python3 - <<'PY'
import json,os
x=json.loads(os.environ["OUT_JSON"])
assert x["ok"] is True,x
a=x["answer"].lower()
assert "arquitect" in a or "estado oficial" in a or "configur" in a,a
assert "snapshot de disco" not in a,a
assert "backup de vm" not in a,a
print("CENTRAL_CHAT_CANONICAL_CONTEXT_OK")
PY

echo "=== 3. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/native-chat-context-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/native-chat-context-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_CONTEXT_SERVICE_OK

echo "=== 4. LIVE INTERFAZ TEST ==="
REQ2=/tmp/interfaz-canonical-context.json
cat >"$REQ2" <<'JSON'
{"text":"¿Qué significa estado canónico en Central?"}
JSON

RESP=$(curl -fsS --max-time 120 -H 'Content-Type: application/json' --data-binary @"$REQ2" http://127.0.0.1:8791/api/message)
echo "$RESP"
RESP_JSON="$RESP" python3 - <<'PY'
import json,os
x=json.loads(os.environ["RESP_JSON"])
assert x["ok"] is True,x
assert x["mode"]=="chat",x
a=x["answer"].lower()
assert "arquitect" in a or "estado oficial" in a or "configur" in a,a
print("INTERFAZ_CANONICAL_CONTEXT_LIVE_OK")
PY

echo CENTRAL_NATIVE_CHAT_CONTEXT_V2_READY
echo "backup=$BACKUP"
