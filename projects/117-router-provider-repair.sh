#!/usr/bin/env bash
set -euo pipefail

CFG=/home/ubuntu/Gemini/config/providers.json
MAIN=/home/ubuntu/Gemini/app/main.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/router-repair-$STAMP
mkdir -p "$BACKUP"
cp -a "$CFG" "$BACKUP/providers.json"
cp -a "$MAIN" "$BACKUP/main.py"

python3 - <<'PY'
import json
from pathlib import Path

cfg=Path("/home/ubuntu/Gemini/config/providers.json")
data=json.loads(cfg.read_text(encoding="utf-8"))
for p in data.get("providers", []):
    pid=str(p.get("id") or "").lower()
    if pid=="openrouter":
        p["key_file"]="/home/ubuntu/Claves/providers/openrouter.key"
    elif pid=="gemini":
        raise SystemExit("GEMINI_MUST_NOT_BE_PRESENT")
cfg.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("PROVIDER_PATHS_FIXED")
PY

python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

if "# GROQ_PAYLOAD_GUARD" not in s:
    needle='''    body = {
        "model": provider["model"],
        "messages": messages,
        "temperature": 0.3,
    }
'''
    repl='''    # GROQ_PAYLOAD_GUARD
    bounded_messages = messages
    if provider.get("id") == "groq":
        max_chars = 24000
        selected = []
        used = 0
        system_msg = messages[0] if messages and messages[0].get("role") == "system" else None
        for msg in reversed(messages):
            content = msg.get("content", "")
            if not isinstance(content, str):
                content = str(content)
            cost = len(content)
            if selected and used + cost > max_chars:
                break
            selected.append(msg)
            used += cost
        bounded_messages = list(reversed(selected))
        if system_msg and (not bounded_messages or bounded_messages[0] is not system_msg):
            bounded_messages.insert(0, system_msg)

    body = {
        "model": provider["model"],
        "messages": bounded_messages,
        "temperature": 0.3,
    }
'''
    if needle not in s:
        raise SystemExit("GROQ_BODY_ANCHOR_NOT_FOUND")
    s=s.replace(needle,repl,1)
    print("GROQ_PAYLOAD_GUARD_ADDED")
else:
    print("GROQ_PAYLOAD_GUARD_PRESENT")

p.write_text(s,encoding="utf-8")
PY

# Apply adaptive priority script if present. It is idempotent.
if [ -f /opt/corex/repo/projects/116-router-adaptive-priority.sh ]; then
  bash /opt/corex/repo/projects/116-router-adaptive-priority.sh
else
  python3 -m py_compile "$MAIN"
  systemctl restart gemini-backend.service
fi

sleep 2
echo "=== PROVIDERS ==="
curl -sS --max-time 5 http://127.0.0.1:8791/api/providers; echo
echo "=== OPENROUTER KEY PATH ==="
python3 - <<'PY'
import json
p=json.load(open("/home/ubuntu/Gemini/config/providers.json"))
for x in p["providers"]:
    if x.get("id")=="openrouter":
        print(x.get("key_file"))
PY
echo ROUTER_PROVIDER_REPAIR_READY
