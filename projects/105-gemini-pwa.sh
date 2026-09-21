#!/usr/bin/env bash
set -euo pipefail

WEB=/home/ubuntu/Gemini/web
INDEX="$WEB/index.html"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/pwa-$STAMP

mkdir -p "$BACKUP" "$WEB/icons"
cp -a "$INDEX" "$BACKUP/index.html"

cat > "$WEB/manifest.webmanifest" <<'EOF'
{
  "id": "/gemini/",
  "name": "Gemini",
  "short_name": "Gemini",
  "description": "Gemini conectado a Central",
  "start_url": "/gemini/?source=pwa",
  "scope": "/gemini/",
  "display": "standalone",
  "background_color": "#0f1115",
  "theme_color": "#0f1115",
  "orientation": "portrait-primary",
  "icons": [
    {
      "src": "./icons/icon-192.png",
      "sizes": "192x192",
      "type": "image/png",
      "purpose": "any"
    },
    {
      "src": "./icons/icon-512.png",
      "sizes": "512x512",
      "type": "image/png",
      "purpose": "any"
    },
    {
      "src": "./icons/icon-512-maskable.png",
      "sizes": "512x512",
      "type": "image/png",
      "purpose": "maskable"
    }
  ]
}
EOF

cat > "$WEB/sw.js" <<'EOF'
const CACHE = 'gemini-pwa-v1';
const SHELL = ['./', './manifest.webmanifest'];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // Nunca cachear API: siempre estado real.
  if (url.pathname.includes('/api/')) return;

  event.respondWith(
    fetch(req)
      .then(resp => {
        const copy = resp.clone();
        caches.open(CACHE).then(cache => cache.put(req, copy));
        return resp;
      })
      .catch(() => caches.match(req).then(hit => hit || caches.match('./')))
  );
});
EOF

python3 - <<'PY'
from pathlib import Path
import struct, zlib

out = Path("/home/ubuntu/Gemini/web/icons")
out.mkdir(parents=True, exist_ok=True)

def png(path, n, maskable=False):
    bg=(15,17,21)
    fg=(245,247,250)
    accent=(120,134,255)
    px=[[bg for _ in range(n)] for __ in range(n)]

    # soft square/accent tile
    pad=int(n*0.16)
    for y in range(pad,n-pad):
        for x in range(pad,n-pad):
            # rounded-square approximation
            r=int(n*0.10)
            dx=max(pad+r-x,0,x-(n-pad-r-1))
            dy=max(pad+r-y,0,y-(n-pad-r-1))
            if dx*dx+dy*dy <= r*r:
                px[y][x]=accent

    # geometric G
    x0,x1=int(n*.31),int(n*.69)
    y0,y1=int(n*.29),int(n*.71)
    t=max(3,int(n*.07))
    # top, left, bottom
    for y in range(y0,y0+t):
        for x in range(x0,x1): px[y][x]=fg
    for y in range(y0,y1):
        for x in range(x0,x0+t): px[y][x]=fg
    for y in range(y1-t,y1):
        for x in range(x0,x1): px[y][x]=fg
    # right lower stem + middle bar
    for y in range(int(n*.50),y1):
        for x in range(x1-t,x1): px[y][x]=fg
    for y in range(int(n*.50),int(n*.50)+t):
        for x in range(int(n*.50),x1): px[y][x]=fg

    raw=bytearray()
    for row in px:
        raw.append(0)
        for r,g,b in row: raw.extend((r,g,b))

    def chunk(tag,data):
        return struct.pack(">I",len(data))+tag+data+struct.pack(">I",zlib.crc32(tag+data)&0xffffffff)

    data=b"\x89PNG\r\n\x1a\n"
    data+=chunk(b'IHDR',struct.pack(">IIBBBBB",n,n,8,2,0,0,0))
    data+=chunk(b'IDAT',zlib.compress(bytes(raw),9))
    data+=chunk(b'IEND',b'')
    path.write_bytes(data)

png(out/"icon-192.png",192)
png(out/"icon-512.png",512)
png(out/"icon-512-maskable.png",512,True)
print("ICONS_OK")
PY

python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Gemini/web/index.html")
s=p.read_text(encoding="utf-8")

head_bits = '''
  <link rel="manifest" href="/gemini/manifest.webmanifest">
  <meta name="theme-color" content="#0f1115">
  <meta name="mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <meta name="apple-mobile-web-app-title" content="Gemini">
  <link rel="apple-touch-icon" href="./icons/icon-192.png">
'''

if 'manifest.webmanifest' not in s:
    pos=s.lower().find('</head>')
    if pos < 0:
        raise SystemExit("HEAD_NOT_FOUND")
    s=s[:pos]+head_bits+s[pos:]

reg = '''
<script>
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/gemini/sw.js', { scope: '/gemini/' }).catch(() => {});
  });
}
</script>
'''

if "serviceWorker.register('./sw.js'" not in s:
    pos=s.lower().rfind('</body>')
    if pos < 0:
        raise SystemExit("BODY_NOT_FOUND")
    s=s[:pos]+reg+s[pos:]

p.write_text(s,encoding="utf-8")
print("INDEX_PWA_PATCH_OK")
PY

echo "=== FILES ==="
ls -lh "$WEB/manifest.webmanifest" "$WEB/sw.js" "$WEB/icons/icon-192.png" "$WEB/icons/icon-512.png"

echo "=== LOCAL HTTP ==="
curl -fsS --max-time 5 http://127.0.0.1:8791/ >/dev/null 2>&1 || true

echo GEMINI_PWA_READY
