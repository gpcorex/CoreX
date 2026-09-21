#!/usr/bin/env bash
set -euo pipefail

OLD=/home/ubuntu/Claves/prov/openrouter.key
NEW=/home/ubuntu/Claves/providers/openrouter.key
CFG=/home/ubuntu/Gemini/config/providers.json

if [ ! -s "$NEW" ]; then
  echo "NEW_OPENROUTER_KEY_MISSING_ABORT"
  exit 1
fi

rm -f "$OLD"

python3 - <<'PY'
import json
from pathlib import Path

cfg=Path("/home/ubuntu/Gemini/config/providers.json")
data=json.loads(cfg.read_text(encoding="utf-8"))

found=False
for p in data.get("providers", []):
    if str(p.get("id") or "").lower()=="openrouter":
        p["key_file"]="/home/ubuntu/Claves/providers/openrouter.key"
        found=True

if not found:
    raise SystemExit("OPENROUTER_PROVIDER_NOT_FOUND")

cfg.write_text(
    json.dumps(data,ensure_ascii=False,indent=2)+"\n",
    encoding="utf-8"
)
print("OPENROUTER_CONFIG_POINTS_TO_NEW_KEY")
PY

echo "OLD_KEY_EXISTS=$(test -e "$OLD" && echo yes || echo no)"
echo "NEW_KEY_EXISTS=$(test -s "$NEW" && echo yes || echo no)"
echo OPENROUTER_OLD_KEY_REMOVED
