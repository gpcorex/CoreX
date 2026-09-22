#!/usr/bin/env bash
set -euo pipefail

CADDY=/etc/caddy/Caddyfile
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/root-pwa-scope-split-$STAMP
STATIC=/srv/central-root-pwa
mkdir -p "$BACKUP" "$STATIC"
cp -a "$CADDY" "$BACKUP/Caddyfile"

echo "=== 1. AUDIT ROOT CENTRAL PWA ==="
HTML=$(curl -fsS --max-time 10 http://127.0.0.1:8090/)
printf '%s' "$HTML" >"$BACKUP/root.html"

MANIFEST_HREF=$(python3 - "$BACKUP/root.html" <<'PY'
import re,sys
s=open(sys.argv[1],encoding="utf-8",errors="replace").read()
m=re.search(r'<link[^>]+rel=["\']manifest["\'][^>]+href=["\']([^"\']+)["\']',s,re.I)
if not m:
    m=re.search(r'<link[^>]+href=["\']([^"\']+)["\'][^>]+rel=["\']manifest["\']',s,re.I)
print(m.group(1) if m else "")
PY
)

echo "manifest_href=$MANIFEST_HREF"
if [ -z "$MANIFEST_HREF" ]; then
  echo ROOT_MANIFEST_NOT_FOUND
  exit 1
fi

case "$MANIFEST_HREF" in
  http://*|https://*) MANIFEST_URL="$MANIFEST_HREF" ;;
  /*) MANIFEST_URL="http://127.0.0.1:8090$MANIFEST_HREF" ;;
  *) MANIFEST_URL="http://127.0.0.1:8090/${MANIFEST_HREF#./}" ;;
esac

curl -fsS --max-time 10 "$MANIFEST_URL" >"$BACKUP/root-manifest-original.json"
cat "$BACKUP/root-manifest-original.json"
echo

python3 - "$BACKUP/root-manifest-original.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1],encoding="utf-8"))
print("root_name="+str(m.get("name")))
print("root_id="+str(m.get("id")))
print("root_start_url="+str(m.get("start_url")))
print("root_scope="+str(m.get("scope")))
PY
echo ROOT_PWA_AUDIT_OK

echo "=== 2. CREATE NARROW-SCOPE CENTRAL MANIFEST ==="
python3 - "$BACKUP/root-manifest-original.json" "$STATIC/manifest.webmanifest" <<'PY'
import json,sys
src,dst=sys.argv[1:]
m=json.load(open(src,encoding="utf-8"))
m["id"]="/central/"
m["name"]=m.get("name") or "Central"
m["short_name"]=m.get("short_name") or "Central"
m["start_url"]="/central/"
m["scope"]="/central/"
json.dump(m,open(dst,"w",encoding="utf-8"),ensure_ascii=False,separators=(",",":"))
PY
cat "$STATIC/manifest.webmanifest"
echo
echo ROOT_PWA_NARROW_MANIFEST_OK

echo "=== 3. PATCH CADDY: /central/ ALIAS + ROOT MANIFEST OVERRIDE ==="
python3 - "$CADDY" "$MANIFEST_HREF" <<'PY'
from pathlib import Path
import sys
from urllib.parse import urlparse
p=Path(sys.argv[1])
href=sys.argv[2]
s=p.read_text(encoding="utf-8")

if href.startswith("http://") or href.startswith("https://"):
    manifest_path=urlparse(href).path
elif href.startswith("/"):
    manifest_path=href
else:
    manifest_path="/"+href.lstrip("./")

marker="# CENTRAL_ROOT_PWA_SCOPE_SPLIT"
if marker not in s:
    candidates=[
'''    route {
        reverse_proxy 127.0.0.1:8090
    }
''',
'''    reverse_proxy 127.0.0.1:8090
'''
    ]
    needle=next((x for x in candidates if x in s),None)
    if not needle:
        raise SystemExit("CADDY_ROOT_PROXY_ANCHOR_NOT_FOUND")

    block=f'''    {marker}
    route /central {{
        redir /central/ 308
    }}

    route /central/* {{
        uri strip_prefix /central
        reverse_proxy 127.0.0.1:8090
    }}

    route {manifest_path} {{
        root * /srv/central-root-pwa
        rewrite * /manifest.webmanifest
        header Content-Type "application/manifest+json; charset=utf-8"
        header Cache-Control "no-cache"
        file_server
    }}

'''
    s=s.replace(needle,block+needle,1)
    p.write_text(s,encoding="utf-8")
PY

caddy validate --config "$CADDY"
sudo systemctl reload caddy
echo CADDY_ROOT_PWA_SCOPE_SPLIT_OK

echo "=== 4. VALIDATE PUBLIC CENTRAL ALIAS + MANIFEST ==="
curl -fsSI --max-time 20 https://cen-tral.duckdns.org/central/ | head -n 1

if [[ "$MANIFEST_HREF" == http://* || "$MANIFEST_HREF" == https://* ]]; then
  PUB_MAN="$MANIFEST_HREF"
elif [[ "$MANIFEST_HREF" == /* ]]; then
  PUB_MAN="https://cen-tral.duckdns.org$MANIFEST_HREF"
else
  PUB_MAN="https://cen-tral.duckdns.org/${MANIFEST_HREF#./}"
fi

curl -fsS --max-time 20 "$PUB_MAN" >/tmp/root-central-public-manifest.json
cat /tmp/root-central-public-manifest.json
echo
python3 - <<'PY'
import json
m=json.load(open("/tmp/root-central-public-manifest.json",encoding="utf-8"))
assert m["id"]=="/central/",m
assert m["start_url"]=="/central/",m
assert m["scope"]=="/central/",m
print("ROOT_CENTRAL_SCOPE_PUBLIC_OK")
PY

echo "=== 5. VERIFY CHAT MANIFEST REMAINS SEPARATE ==="
curl -fsS --max-time 20 https://cen-tral.duckdns.org/interfaz/manifest.webmanifest >/tmp/chat-manifest-split.json
python3 - <<'PY'
import json
m=json.load(open("/tmp/chat-manifest-split.json",encoding="utf-8"))
assert m["id"]=="/interfaz/",m
assert m["start_url"]=="/interfaz/",m
assert m["scope"]=="/interfaz/",m
print("CHAT_SCOPE_STILL_SEPARATE_OK")
PY

echo "=== 6. FINAL SPLIT ==="
echo "Central general: https://cen-tral.duckdns.org/central/"
echo "Central Chat:    https://cen-tral.duckdns.org/interfaz/"
echo ROOT_AND_CHAT_PWA_SCOPES_SPLIT_READY
echo "backup=$BACKUP"
echo "NOTE=The already-installed old Central app on Android may keep its old / scope until it is removed/reinstalled. Reinstall Central from /central/ after this validation."
