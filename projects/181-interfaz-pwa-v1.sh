#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Interfaz/server.py
APP=/home/ubuntu/Interfaz
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/interfaz-pwa-v1-$STAMP

mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. PATCH INTERFAZ WITH PWA ENDPOINTS + REGISTRATION ==="
python3 - <<'PY'
from pathlib import Path
import re
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

# Ensure struct/zlib imports for generated PNG icons.
lines=s.splitlines()
for i,line in enumerate(lines):
    if line.startswith("import ") and "json" in line and "sqlite3" in line:
        if "struct" not in line:
            if "zlib" in line:
                line=line.replace("sqlite3,","sqlite3, struct,")
            else:
                line=line.replace("sqlite3,","sqlite3, struct, zlib,")
            lines[i]=line
        break
s="\n".join(lines)+"\n"

# Add PWA helpers before class H.
if "def pwa_icon_png(" not in s:
    anchor="class H(BaseHTTPRequestHandler):\n"
    if anchor not in s:
        raise SystemExit("PWA_CLASS_ANCHOR_NOT_FOUND")
    helpers=r'''
def pwa_icon_png(size:int)->bytes:
    # Minimal generated PNG: dark background with a centered light "C"-style ring.
    w=h=size
    rows=[]
    cx=cy=size/2
    outer=size*0.34
    inner=size*0.23
    gap_angle=0.30
    import math
    for y in range(h):
        row=bytearray()
        for x in range(w):
            dx=x+0.5-cx; dy=y+0.5-cy
            r=(dx*dx+dy*dy)**0.5
            a=math.atan2(dy,dx)
            bg=(15,17,21,255)
            fg=(238,242,247,255)
            use=(inner <= r <= outer and not (-gap_angle <= a <= gap_angle))
            row.extend(fg if use else bg)
        rows.append(b"\x00"+bytes(row))
    raw=b"".join(rows)
    def chunk(t,d):
        return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
    return (
        b"\x89PNG\r\n\x1a\n"
        +chunk(b"IHDR",struct.pack(">IIBBBBB",w,h,8,6,0,0,0))
        +chunk(b"IDAT",zlib.compress(raw,9))
        +chunk(b"IEND",b"")
    )

PWA_MANIFEST={
    "name":"Central",
    "short_name":"Central",
    "description":"Interfaz conversacional y operativa de Central",
    "start_url":"./",
    "scope":"./",
    "display":"standalone",
    "background_color":"#0f1115",
    "theme_color":"#0f1115",
    "orientation":"any",
    "icons":[
        {"src":"icons/icon-192.png","sizes":"192x192","type":"image/png","purpose":"any maskable"},
        {"src":"icons/icon-512.png","sizes":"512x512","type":"image/png","purpose":"any maskable"}
    ]
}

PWA_SW=r"""const CACHE='central-chat-pwa-v1';
const CORE=['./','manifest.webmanifest','icons/icon-192.png','icons/icon-512.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(CORE)).catch(()=>{}));self.skipWaiting()});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))));self.clients.claim()});
self.addEventListener('fetch',e=>{
  const u=new URL(e.request.url);
  if(e.request.method!=='GET') return;
  if(u.pathname.includes('/api/')) return;
  e.respondWith(fetch(e.request).then(r=>{
    const copy=r.clone(); caches.open(CACHE).then(c=>c.put(e.request,copy)).catch(()=>{}); return r;
  }).catch(()=>caches.match(e.request).then(r=>r||caches.match('./'))));
});
"""
'''
    s=s.replace(anchor,helpers+"\n"+anchor,1)

# Add binary/text asset sender methods into handler.
if "def send_asset(self," not in s:
    anchor='''    def read_json(self):
        n=int(self.headers.get("Content-Length","0") or 0)
        return json.loads(self.rfile.read(n) or b"{}")
'''
    insert='''    def read_json(self):
        n=int(self.headers.get("Content-Length","0") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def send_asset(self,code,raw,content_type,cache="public, max-age=86400"):
        if isinstance(raw,str): raw=raw.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type",content_type)
        self.send_header("Cache-Control",cache)
        self.send_header("Content-Length",str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
'''
    if anchor not in s:
        raise SystemExit("PWA_SEND_ASSET_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert,1)

# Add GET routes immediately after p=...
if 'p=="/manifest.webmanifest"' not in s:
    anchor='''    def do_GET(self):
        p=urlparse(self.path).path
'''
    insert='''    def do_GET(self):
        p=urlparse(self.path).path
        if p=="/manifest.webmanifest":
            return self.send_asset(200,json.dumps(PWA_MANIFEST,ensure_ascii=False,separators=(",",":")),"application/manifest+json; charset=utf-8","no-cache")
        if p=="/sw.js":
            return self.send_asset(200,PWA_SW,"application/javascript; charset=utf-8","no-cache")
        if p=="/icons/icon-192.png":
            return self.send_asset(200,pwa_icon_png(192),"image/png")
        if p=="/icons/icon-512.png":
            return self.send_asset(200,pwa_icon_png(512),"image/png")
'''
    if anchor not in s:
        raise SystemExit("PWA_GET_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert,1)

# Add manifest/meta to <head>.
if 'rel="manifest"' not in s:
    anchor='<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
    insert=anchor+'''<meta name="theme-color" content="#0f1115">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<link rel="manifest" href="manifest.webmanifest">
<link rel="icon" type="image/png" sizes="192x192" href="icons/icon-192.png">
<link rel="apple-touch-icon" href="icons/icon-192.png">
'''
    if anchor not in s:
        raise SystemExit("PWA_HEAD_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert,1)

# Register service worker near end of script.
if "serviceWorker.register('sw.js'" not in s:
    anchor='''loadConvs()
</script>
'''
    insert='''loadConvs()
if('serviceWorker' in navigator){
  window.addEventListener('load',()=>navigator.serviceWorker.register('sw.js',{scope:'./'}).catch(()=>{}))
}
</script>
'''
    if anchor not in s:
        raise SystemExit("PWA_SW_REGISTER_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo INTERFAZ_PWA_PATCH_OK

echo "=== 2. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/interfaz-pwa-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/interfaz-pwa-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_PWA_SERVICE_OK

echo "=== 3. LOCAL PWA ASSET VALIDATION ==="
HTML=$(curl -fsS --max-time 10 http://127.0.0.1:8791/)
grep -q 'rel="manifest"' <<<"$HTML"
grep -q "serviceWorker.register('sw.js'" <<<"$HTML"

MAN=$(curl -fsS --max-time 10 http://127.0.0.1:8791/manifest.webmanifest)
MAN_JSON="$MAN" python3 - <<'PY'
import json,os
m=json.loads(os.environ["MAN_JSON"])
assert m["id"]=="/interfaz/",m
assert m["name"]=="Central Chat",m
assert m["display"]=="standalone",m
assert m["start_url"]=="./",m
assert m["scope"]=="./",m
sizes={x["sizes"] for x in m["icons"]}
assert {"192x192","512x512"} <= sizes,m
print("PWA_MANIFEST_VALID_OK")
PY

curl -fsS --max-time 10 http://127.0.0.1:8791/sw.js | grep -q "central-chat-pwa-v1"
[ "$(curl -fsS --max-time 10 http://127.0.0.1:8791/icons/icon-192.png | wc -c)" -gt 1000 ]
[ "$(curl -fsS --max-time 10 http://127.0.0.1:8791/icons/icon-512.png | wc -c)" -gt 1000 ]
echo PWA_LOCAL_ASSETS_OK

echo "=== 4. PUBLIC HTTPS PWA VALIDATION ==="
BASE=https://cen-tral.duckdns.org/interfaz
PUB=$(curl -fsS --max-time 20 "$BASE/")
grep -q 'rel="manifest"' <<<"$PUB"
grep -q "serviceWorker.register('sw.js'" <<<"$PUB"

curl -fsS --max-time 20 "$BASE/manifest.webmanifest" >/tmp/central-public-manifest.json
python3 - <<'PY'
import json
m=json.load(open("/tmp/central-public-manifest.json",encoding="utf-8"))
assert m["display"]=="standalone"
assert m["start_url"]=="./"
assert m["scope"]=="./"
print("PWA_PUBLIC_MANIFEST_OK")
PY

curl -fsSI --max-time 20 "$BASE/sw.js" | grep -qi 'content-type: application/javascript'
curl -fsSI --max-time 20 "$BASE/icons/icon-192.png" | grep -qi 'content-type: image/png'
curl -fsSI --max-time 20 "$BASE/icons/icon-512.png" | grep -qi 'content-type: image/png'
echo PWA_PUBLIC_ASSETS_OK

echo "=== 5. FINAL INSTALLABILITY MARKERS ==="
echo "HTTPS=https://cen-tral.duckdns.org/interfaz/"
echo "pwa_id=/interfaz/"\necho "name=Central Chat"\necho "manifest=yes"
echo "service_worker=yes"
echo "icon_192=yes"
echo "icon_512=yes"
echo "display=standalone"
echo CENTRAL_INTERFAZ_PWA_V1_READY
echo "backup=$BACKUP"
