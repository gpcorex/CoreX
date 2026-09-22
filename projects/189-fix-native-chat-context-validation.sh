#!/usr/bin/env bash
set -euo pipefail

CHAT=/home/ubuntu/Central/native_v1/native_chat.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-chat-context-test-fix-$STAMP
mkdir -p "$BACKUP"
cp -a "$CHAT" "$BACKUP/native_chat.py"

echo "=== 1. VERIFY CURRENT CONTEXT PATCH ==="
python3 -m py_compile "$CHAT"
grep -q "estado canónico" "$CHAT"
grep -q "No inventes equipos humanos" "$CHAT"
echo CENTRAL_CHAT_CONTEXT_PATCH_PRESENT_OK

echo "=== 2. DIRECT SEMANTIC CONTEXT TEST ==="
REQ=/tmp/native-chat-central-context-v2.json
cat >"$REQ" <<'JSON'
{"messages":[{"role":"user","content":"¿Qué significa estado canónico en Central?"}]}
JSON

OUT=$(sudo -u ubuntu env PYTHONPATH=/home/ubuntu/Central/native_v1 /usr/bin/python3 "$CHAT" < "$REQ")
echo "$OUT"
OUT_JSON="$OUT" python3 - <<'PY'
import json,os,re
x=json.loads(os.environ["OUT_JSON"])
assert x["ok"] is True,x
a=x["answer"].lower()
assert any(k in a for k in ("estado oficial","referencia oficial","arquitectura","configuración","configuracion")),a
# Mentioning disk snapshots in a negation is correct; reject only if the answer defines
# canonical state AS a disk/VM snapshot.
bad=[
    "estado canónico es un snapshot de disco",
    "estado canonico es un snapshot de disco",
    "estado canónico es una copia de seguridad de la vm",
    "estado canonico es una copia de seguridad de la vm",
]
assert not any(b in a for b in bad),a
assert ("no" in a and ("snapshot de disco" in a or "copia de seguridad" in a)) or "fuente de verdad" in a,a
print("CENTRAL_CHAT_CANONICAL_CONTEXT_OK")
PY

echo "=== 3. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/native-chat-context-v2-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/native-chat-context-v2-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_CONTEXT_SERVICE_OK

echo "=== 4. LIVE INTERFAZ CONTEXT TEST ==="
REQ2=/tmp/interfaz-canonical-context-v2.json
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
assert any(k in a for k in ("estado oficial","referencia oficial","arquitectura","configuración","configuracion")),a
assert not any(b in a for b in (
    "estado canónico es un snapshot de disco",
    "estado canonico es un snapshot de disco",
    "estado canónico es una copia de seguridad de la vm",
    "estado canonico es una copia de seguridad de la vm",
)),a
print("INTERFAZ_CANONICAL_CONTEXT_LIVE_OK")
PY

echo CENTRAL_NATIVE_CHAT_CONTEXT_V2_READY
echo "backup=$BACKUP"
