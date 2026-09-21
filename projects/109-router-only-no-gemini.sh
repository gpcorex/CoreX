#!/usr/bin/env bash
set -euo pipefail

MAIN=/home/ubuntu/Gemini/app/main.py
CFG=/home/ubuntu/Gemini/config/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/router-no-gemini-$STAMP
mkdir -p "$BACKUP"
cp -a "$MAIN" "$BACKUP/main.py"
cp -a "$CFG" "$BACKUP/providers.json"

echo "=== REMOVE GEMINI PROVIDER FROM CONFIG ==="
python3 - <<'PY'
import json
from pathlib import Path

p=Path("/home/ubuntu/Gemini/config/providers.json")
data=json.loads(p.read_text(encoding="utf-8"))
providers=data.get("providers", [])
kept=[]
removed=[]
for item in providers:
    pid=str(item.get("id") or item.get("name") or "").strip().lower()
    ptype=str(item.get("type") or "").strip().lower()
    if pid=="gemini" or ptype in {"gemini","google_gemini"}:
        removed.append(item)
    else:
        kept.append(item)

data["providers"]=kept
p.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("removed=", [x.get("id") or x.get("name") for x in removed])
print("remaining=", [x.get("id") or x.get("name") for x in kept])
if any((str(x.get("id") or x.get("name") or "").lower()=="gemini") for x in kept):
    raise SystemExit("GEMINI_STILL_PRESENT")
if not kept:
    raise SystemExit("NO_PROVIDERS_LEFT")
PY

echo "=== ROUTE NORMAL CHAT TO REAL ROUTER ==="
python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

marker='    # ROUTER_ONLY_NORMAL_CHAT\n'
if marker in s:
    print("ROUTER_ONLY_ALREADY_PRESENT")
else:
    func='async def api_chat_direct(data: ChatInput):\n'
    pos=s.find(func)
    if pos<0:
        raise SystemExit("API_CHAT_DIRECT_NOT_FOUND")

    empty='''    if not message:
        raise HTTPException(
            status_code=400,
            detail="Mensaje vacío",
        )
'''
    anchor=s.find(empty,pos)
    if anchor<0:
        raise SystemExit("DIRECT_EMPTY_GUARD_NOT_FOUND")
    insert_at=anchor+len(empty)

    block='''

    # ROUTER_ONLY_NORMAL_CHAT
    # Normal conversation goes straight to the existing routed /api/chat.
    # Programming/VM requests continue below through Central.
    if not _looks_like_programming_request(message):
        return await _call_original_chat(data)
'''
    s=s[:insert_at]+block+s[insert_at:]
    p.write_text(s,encoding="utf-8")
    print("ROUTER_ONLY_PATCH_OK")
PY

python3 -m py_compile "$MAIN"

echo "=== RESTART GEMINI ONCE ==="
systemctl restart gemini-backend.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/gem-no-gem-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done

cat /tmp/gem-no-gem-health.json

echo
echo "=== ACTIVE PROVIDERS ==="
curl -fsS --max-time 5 http://127.0.0.1:8791/api/providers | tee /tmp/gem-no-gem-providers.json
echo

python3 - <<'PY'
import json
from pathlib import Path
p=Path("/tmp/gem-no-gem-providers.json")
data=json.loads(p.read_text())
ids=[str(x.get("id") or "").lower() for x in data]
print("provider_ids=",ids)
if "gemini" in ids:
    raise SystemExit("GEMINI_PROVIDER_VISIBLE")
if not ids:
    raise SystemExit("NO_ACTIVE_PROVIDERS")
print("NO_GEMINI_PROVIDER_OK")
PY

echo
echo "=== ROUTER PATCH CHECK ==="
grep -n -A5 -B2 'ROUTER_ONLY_NORMAL_CHAT' "$MAIN"

echo
echo GEMINI_PROVIDER_REMOVED_ROUTER_ONLY_READY
