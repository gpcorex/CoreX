#!/usr/bin/env bash
set -euo pipefail

MAIN=/home/ubuntu/Gemini/app/main.py
CFG=/home/ubuntu/Gemini/config/providers.json
DB=/home/ubuntu/Gemini/data/gemini.db
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/router-live-repair-$STAMP
mkdir -p "$BACKUP"
cp -a "$MAIN" "$BACKUP/main.py"
cp -a "$CFG" "$BACKUP/providers.json"
[ -f "$DB" ] && cp -a "$DB" "$BACKUP/gemini.db" || true

python3 - <<'PY'
import json
from pathlib import Path

cfg=Path("/home/ubuntu/Gemini/config/providers.json")
data=json.loads(cfg.read_text(encoding="utf-8"))
for p in data.get("providers", []):
    pid=str(p.get("id") or "").lower()
    if pid=="openrouter":
        p["key_file"]="/home/ubuntu/Claves/providers/openrouter.key"
    if pid=="gemini":
        raise SystemExit("GEMINI_PRESENT_ABORT")
cfg.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("OPENROUTER_KEY_PATH_OK")
PY

python3 - <<'PY'
from pathlib import Path
import re

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

# Replace the previous GROQ payload guard with a stricter total-budget guard.
start=s.find("    # GROQ_PAYLOAD_GUARD")
if start >= 0:
    body=s.find('    body = {\n        "model": provider["model"],\n        "messages": bounded_messages,\n        "temperature": 0.3,\n    }', start)
    if body < 0:
        raise SystemExit("GROQ_GUARD_BODY_NOT_FOUND")
    end=body+len('    body = {\n        "model": provider["model"],\n        "messages": bounded_messages,\n        "temperature": 0.3,\n    }')
    new='''    # GROQ_PAYLOAD_GUARD
    bounded_messages = messages
    if provider.get("id") == "groq":
        # Bound the ENTIRE request, including the system prompt.
        # This avoids 413 even when project memory/system context is large.
        total_budget = 12000
        system_budget = 4000
        tail_budget = total_budget - system_budget

        system_part = []
        tail = []

        if messages and messages[0].get("role") == "system":
            sm = dict(messages[0])
            content = sm.get("content", "")
            if not isinstance(content, str):
                content = str(content)
            sm["content"] = content[:system_budget]
            system_part = [sm]

        used = 0
        for msg in reversed(messages[1:] if system_part else messages):
            item = dict(msg)
            content = item.get("content", "")
            if not isinstance(content, str):
                content = str(content)
            remaining = tail_budget - used
            if remaining <= 0:
                break
            if len(content) > remaining:
                content = content[-remaining:]
            item["content"] = content
            tail.append(item)
            used += len(content)

        bounded_messages = system_part + list(reversed(tail))

    body = {
        "model": provider["model"],
        "messages": bounded_messages,
        "temperature": 0.3,
    }'''
    s=s[:start]+new+s[end:]
    print("GROQ_TOTAL_PAYLOAD_GUARD_UPDATED")
else:
    print("GROQ_GUARD_NOT_PRESENT")
p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$MAIN"

python3 - <<'PY'
import sqlite3
from pathlib import Path

db=Path("/home/ubuntu/Gemini/data/gemini.db")
if not db.exists():
    print("DB_NOT_FOUND_SKIP_STATE_RESET")
    raise SystemExit(0)

con=sqlite3.connect(db)
tables={r[0] for r in con.execute("select name from sqlite_master where type='table'")}
for name in ("provider_state","provider_status","provider_cooldowns"):
    if name in tables:
        con.execute(f"delete from {name}")
        print("CLEARED", name)
con.commit()
con.close()
PY

systemctl restart gemini-backend.service
for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/router-live-health.json 2>/dev/null && break
  sleep 1
done

echo "=== HEALTH ==="
cat /tmp/router-live-health.json
echo
echo "=== PROVIDERS AFTER RESET ==="
curl -sS --max-time 5 http://127.0.0.1:8791/api/providers; echo

PY=/home/ubuntu/Gemini/.venv/bin/python
if [ ! -x "$PY" ]; then PY=/usr/bin/python3; fi

"$PY" - <<'PY'
from pathlib import Path
import asyncio, httpx

async def main():
    # OpenRouter credential check
    key=Path("/home/ubuntu/Claves/providers/openrouter.key").read_text().strip()
    h={"Authorization":f"Bearer {key}","HTTP-Referer":"http://127.0.0.1","X-Title":"Central"}
    async with httpx.AsyncClient(timeout=20) as c:
        r=await c.get("https://openrouter.ai/api/v1/models",headers=h)
        print("OPENROUTER_MODELS_STATUS", r.status_code)

    # Groq minimal transport/auth check. 200 or 429 proves the key reaches Groq.
    gpath=Path("/home/ubuntu/Claves/prov/groq.key")
    if gpath.exists():
        gkey=gpath.read_text().strip()
        gh={"Authorization":f"Bearer {gkey}","Content-Type":"application/json"}
        payload={"model":"openai/gpt-oss-120b","messages":[{"role":"user","content":"Reply only OK"}],"max_tokens":8}
        async with httpx.AsyncClient(timeout=20) as c:
            gr=await c.post("https://api.groq.com/openai/v1/chat/completions",headers=gh,json=payload)
            print("GROQ_STATUS", gr.status_code)

asyncio.run(main())
PY

echo ROUTER_LIVE_REPAIR_READY
