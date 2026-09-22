#!/usr/bin/env bash
set -euo pipefail

KEY_FILE="/home/ubuntu/Claves/prov/groq.key"
[ -s "$KEY_FILE" ] || { echo "GROQ_KEY_NOT_FOUND"; exit 1; }

KEY="$(tr -d '\r\n' < "$KEY_FILE")"

echo "=== GROQ MODELS AVAILABLE TO THIS KEY ==="
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

HTTP=$(curl -sS -o "$TMP" -w '%{http_code}' --max-time 20 \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  https://api.groq.com/openai/v1/models)

echo "http=$HTTP"
[ "$HTTP" = "200" ] || { cat "$TMP"; exit 1; }

python3 - "$TMP" <<'PY'
import json,sys
p=sys.argv[1]
data=json.load(open(p,encoding="utf-8"))
models=sorted((x.get("id") or "") for x in data.get("data",[]) if x.get("id"))
print("count=",len(models),sep="")
for m in models:
    print(m)
PY

echo "=== CURRENT OPENCLAW GROQ CATALOG ==="
python3 - <<'PY'
import json
from pathlib import Path
p=Path("/home/ubuntu/.openclaw/openclaw.json")
cfg=json.loads(p.read_text(encoding="utf-8"))
groq=((cfg.get("models") or {}).get("providers") or {}).get("groq") or {}
for x in groq.get("models") or []:
    if isinstance(x,dict):
        print(x.get("id"))
    else:
        print(x)
PY

echo "GROQ_MODEL_AUDIT_OK"
