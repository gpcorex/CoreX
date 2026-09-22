#!/usr/bin/env bash
set -euo pipefail

GROQ_KEY="$(tr -d '\r\n' < /home/ubuntu/Claves/prov/groq.key)"
OR_KEY="$(tr -d '\r\n' < /home/ubuntu/Claves/providers/openrouter.key)"

echo "=== GROQ 20B ==="
curl -sS --max-time 45 -w '\nHTTP=%{http_code}\n' \
  -H "Authorization: Bearer $GROQ_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-oss-20b","messages":[{"role":"user","content":"Respondé exactamente OK"}],"max_completion_tokens":64}' \
  https://api.groq.com/openai/v1/chat/completions | head -c 2500
echo

echo "=== OPENROUTER LAGUNA ==="
curl -sS --max-time 60 -w '\nHTTP=%{http_code}\n' \
  -H "Authorization: Bearer $OR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"poolside/laguna-s-2.1:free","messages":[{"role":"user","content":"Respondé exactamente OK"}],"max_tokens":128}' \
  https://openrouter.ai/api/v1/chat/completions | head -c 3000
echo

echo "=== OPENCLAW POLICY ==="
python3 - <<'PY'
import json
from pathlib import Path
cfg=json.loads(Path("/home/ubuntu/.openclaw/openclaw.json").read_text())
print(json.dumps(cfg.get("agents",{}).get("defaults",{}).get("model",{}),ensure_ascii=False,indent=2))
print("tools=",json.dumps(cfg.get("tools",{}),ensure_ascii=False))
PY

echo PROVIDER_DIRECT_DIAG_OK
