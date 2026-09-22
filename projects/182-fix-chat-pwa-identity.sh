#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Interfaz/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/interfaz-pwa-identity-fix-$STAMP
mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. FORCE SEPARATE PWA IDENTITY FOR CHAT ==="
python3 - <<'PY'
from pathlib import Path
import re
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

# Ensure the existing manifest gets a distinct identity, regardless of earlier 181 runs.
m=re.search(r'PWA_MANIFEST=\{.*?\n\}',s,re.S)
if not m:
    raise SystemExit("PWA_MANIFEST_BLOCK_NOT_FOUND")

block=m.group(0)

def set_string(block,key,value):
    pat=rf'("{re.escape(key)}"\s*:\s*)"[^"]*"'
    if re.search(pat,block):
        return re.sub(pat,rf'\1"{value}"',block,count=1)
    # Add missing key immediately after opening brace.
    return block.replace("PWA_MANIFEST={","PWA_MANIFEST={\n    "+repr(key)+":"+repr(value)+",",1)

# Use explicit JSON-style quoting for missing id if needed.
if re.search(r'"id"\s*:',block):
    block=re.sub(r'("id"\s*:\s*)"[^"]*"',r'\1"/interfaz/"',block,count=1)
else:
    block=block.replace("PWA_MANIFEST={",'PWA_MANIFEST={\n    "id":"/interfaz/",',1)

for key,value in [
    ("name","Central Chat"),
    ("short_name","Chat"),
    ("start_url","/interfaz/"),
    ("scope","/interfaz/"),
]:
    pat=rf'("{key}"\s*:\s*)"[^"]*"'
    if not re.search(pat,block):
        raise SystemExit("PWA_MANIFEST_KEY_MISSING:"+key)
    block=re.sub(pat,rf'\1"{value}"',block,count=1)

s=s[:m.start()]+block+s[m.end():]

# Bump cache name so an already-open old standalone shell cannot pin old assets.
s=re.sub(r"const CACHE='[^']+';","const CACHE='central-chat-pwa-v2';",s,count=1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo PWA_CHAT_IDENTITY_PATCH_OK

echo "=== 2. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/pwa-id-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/pwa-id-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_PWA_IDENTITY_SERVICE_OK

echo "=== 3. LOCAL MANIFEST VALIDATION ==="
MAN=$(curl -fsS --max-time 10 http://127.0.0.1:8791/manifest.webmanifest)
echo "$MAN"
MAN_JSON="$MAN" python3 - <<'PY'
import json,os
m=json.loads(os.environ["MAN_JSON"])
assert m["id"]=="/interfaz/",m
assert m["name"]=="Central Chat",m
assert m["short_name"]=="Chat",m
assert m["start_url"]=="/interfaz/",m
assert m["scope"]=="/interfaz/",m
assert m["display"]=="standalone",m
print("PWA_CHAT_MANIFEST_LOCAL_OK")
PY

curl -fsS --max-time 10 http://127.0.0.1:8791/sw.js | grep -q "central-chat-pwa-v2"
echo PWA_CHAT_SW_LOCAL_OK

echo "=== 4. PUBLIC MANIFEST VALIDATION ==="
BASE=https://cen-tral.duckdns.org/interfaz
curl -fsS --max-time 20 "$BASE/manifest.webmanifest" >/tmp/pwa-chat-public-manifest.json
cat /tmp/pwa-chat-public-manifest.json
echo
python3 - <<'PY'
import json
m=json.load(open("/tmp/pwa-chat-public-manifest.json",encoding="utf-8"))
assert m["id"]=="/interfaz/",m
assert m["name"]=="Central Chat",m
assert m["short_name"]=="Chat",m
assert m["start_url"]=="/interfaz/",m
assert m["scope"]=="/interfaz/",m
assert m["display"]=="standalone",m
print("PWA_CHAT_MANIFEST_PUBLIC_OK")
PY

curl -fsS --max-time 20 "$BASE/sw.js" | grep -q "central-chat-pwa-v2"
echo PWA_CHAT_SW_PUBLIC_OK

echo "=== 5. INSTALLATION IDENTITY ==="
echo "existing_root_app=Central"
echo "chat_app=Central Chat"
echo "chat_id=/interfaz/"
echo "chat_start_url=/interfaz/"
echo "chat_scope=/interfaz/"
echo CENTRAL_CHAT_PWA_IDENTITY_READY
echo "backup=$BACKUP"
