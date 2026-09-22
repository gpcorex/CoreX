#!/usr/bin/env bash
set -euo pipefail

CADDY=/etc/caddy/Caddyfile

echo "=== STOP + REMOVE GEMINI SERVICE ==="
systemctl disable --now gemini-backend.service 2>/dev/null || true
rm -f /etc/systemd/system/gemini-backend.service
systemctl daemon-reload
systemctl reset-failed gemini-backend.service 2>/dev/null || true

echo "=== REMOVE GEMINI CADDY ROUTES ==="
if [ -f "$CADDY" ]; then
python3 - <<'PY'
from pathlib import Path
p=Path("/etc/caddy/Caddyfile")
s=p.read_text()

blocks=[
'''    route /gemini {
        redir /gemini/ 308
    }

''',
'''    route /gemini/* {
        uri strip_prefix /gemini
        reverse_proxy 127.0.0.1:8791
    }

'''
]
for b in blocks:
    s=s.replace(b,'')
p.write_text(s)
PY
  caddy validate --config "$CADDY"
  systemctl reload caddy
fi

echo "=== REMOVE GEMINI FILES ==="
rm -rf /home/ubuntu/Gemini
rm -rf /srv/apps/gemini

echo "=== VERIFY ==="
printf 'gemini-backend='
systemctl is-active gemini-backend.service 2>/dev/null || true

if ss -ltnp | grep -q ':8791\b'; then
  echo "ERROR_PORT_8791_STILL_LISTENING"
  ss -ltnp | grep ':8791\b' || true
  exit 1
else
  echo "PORT_8791_FREE"
fi

if grep -nE '/gemini|8791' "$CADDY" 2>/dev/null; then
  echo "ERROR_GEMINI_CADDY_ROUTE_STILL_PRESENT"
  exit 1
else
  echo "GEMINI_CADDY_ROUTE_REMOVED"
fi

for p in /home/ubuntu/Gemini /srv/apps/gemini; do
  if [ -e "$p" ]; then
    echo "ERROR_STILL_EXISTS $p"
    exit 1
  fi
done

echo "GEMINI_FULLY_REMOVED"
