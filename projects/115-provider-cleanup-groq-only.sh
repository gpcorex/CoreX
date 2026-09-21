#!/usr/bin/env bash
set -euo pipefail

MAIN=/home/ubuntu/Gemini/app/main.py
CFG=/home/ubuntu/Gemini/config/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/provider-cleanup-$STAMP
mkdir -p "$BACKUP"
cp -a "$MAIN" "$BACKUP/main.py"
cp -a "$CFG" "$BACKUP/providers.json"

python3 - <<'PY'
import json
from pathlib import Path

cfg=Path("/home/ubuntu/Gemini/config/providers.json")
data=json.loads(cfg.read_text(encoding="utf-8"))
providers=data.get("providers", [])
kept=[]
removed=[]
for p in providers:
    pid=str(p.get("id") or p.get("name") or "").strip().lower()
    if pid=="openrouter":
        removed.append({"id":pid,"reason":"AUTH_401"})
    elif pid=="gemini":
        removed.append({"id":pid,"reason":"BANNED"})
    else:
        kept.append(p)

if not any(str(p.get("id") or "").lower()=="groq" for p in kept):
    raise SystemExit("GROQ_NOT_PRESENT_ABORT")

data["providers"]=kept
cfg.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
Path("/home/ubuntu/Gemini/config/providers.disabled.json").write_text(
    json.dumps({"disabled":removed},ensure_ascii=False,indent=2)+"\n",
    encoding="utf-8"
)
print("ACTIVE=", [p.get("id") for p in kept])
print("REMOVED=", removed)
PY

python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

marker="# GROQ_PAYLOAD_GUARD"
if marker not in s:
    needle='''    body = {
        "model": provider["model"],
        "messages": messages,
        "temperature": 0.3,
    }
'''
    if needle not in s:
        raise SystemExit("OPENAI_BODY_BLOCK_NOT_FOUND")

    replacement='''    # GROQ_PAYLOAD_GUARD
    # Keep normal chat payload bounded so a long conversation cannot
    # make the provider reject the request with HTTP 413.
    bounded_messages = messages
    if provider.get("id") == "groq":
        max_chars = 24000
        selected = []
        used = 0

        # Preserve the first system message when present.
        system_msg = None
        if messages and messages[0].get("role") == "system":
            system_msg = messages[0]

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
        if (
            system_msg
            and (
                not bounded_messages
                or bounded_messages[0] is not system_msg
            )
        ):
            bounded_messages.insert(0, system_msg)

    body = {
        "model": provider["model"],
        "messages": bounded_messages,
        "temperature": 0.3,
    }
'''
    s=s.replace(needle,replacement,1)
    p.write_text(s,encoding="utf-8")
    print("GROQ_PAYLOAD_GUARD_ADDED")
else:
    print("GROQ_PAYLOAD_GUARD_ALREADY_PRESENT")
PY

python3 -m py_compile "$MAIN"
systemctl restart gemini-backend.service

for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/provider-cleanup-health.json 2>/dev/null && break
  sleep 1
done

echo "=== HEALTH ==="
cat /tmp/provider-cleanup-health.json
echo
echo "=== PROVIDERS ==="
curl -sS --max-time 5 http://127.0.0.1:8791/api/providers
echo
echo "=== DISABLED ==="
cat /home/ubuntu/Gemini/config/providers.disabled.json
echo
echo PROVIDER_CLEANUP_GROQ_ONLY_READY
