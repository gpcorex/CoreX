#!/usr/bin/env bash
set -euo pipefail

PWA="/home/ubuntu/Central/media_center/pwa/index.html"
OUT="/var/lib/conector/media-pwa-click-fix.txt"
mkdir -p /var/lib/conector

python3 - "$PWA" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()

old = 'return \'<article class="card" data-title="\'+esc(title.toLowerCase())+\'"><div class="poster">\'+img+\'<span class="badge">\'+esc(label||x.kind||x.quality||"")+\'</span></div><div class="meta"><strong>\'+esc(title)+\'</strong><span>\'+esc(x.kind||x.quality||"")+\'</span></div></article>\';'
new = 'return \'<article class="card" data-title="\'+esc(title.toLowerCase())+\'" data-item-id="\'+esc(x.id||"")+\'"><div class="poster">\'+img+\'<span class="badge">\'+esc(label||x.kind||x.quality||"")+\'</span></div><div class="meta"><strong>\'+esc(title)+\'</strong><span>\'+esc(x.kind||x.quality||"")+\'</span></div></article>\';'

if old not in s:
    raise SystemExit("card return marker not found")

s=s.replace(old,new,1)
p.write_text(s)
PY

sudo systemctl restart media-pwa.service
sleep 1

{
  echo "MEDIA_PWA_CLICK_FIX_READY"
  echo "timestamp=$(date -Is)"
  echo "marker=$(grep -n 'data-item-id' "$PWA" | head -1 || true)"
  echo "public_http=$(curl -sS -o /dev/null -w '%{http_code}' https://cen-tral.duckdns.org/multimedia/ || true)"
  echo "url=https://cen-tral.duckdns.org/multimedia/"
} > "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-pwa-click-fix.txt" || true
fi

cat "$OUT"
