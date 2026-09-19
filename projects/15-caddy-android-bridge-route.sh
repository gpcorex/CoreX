#!/usr/bin/env bash
set -euo pipefail

CADDY="/etc/caddy/Caddyfile"
BACKUP="/etc/caddy/Caddyfile.before-android-bridge"
APP="/srv/apps/android-bridge"

mkdir -p "$APP/data"

if [ ! -f "$CADDY" ]; then
  echo "Caddyfile no encontrado" >&2
  exit 1
fi

cp -a "$CADDY" "$BACKUP"

if ! grep -q 'route /android-bridge/\*' "$CADDY"; then
python3 - <<'PY'
from pathlib import Path

p = Path("/etc/caddy/Caddyfile")
text = p.read_text()

needle = """    route {
        reverse_proxy 127.0.0.1:8090
    }
"""

insert = """    route /android-bridge/* {
        uri strip_prefix /android-bridge
        reverse_proxy 127.0.0.1:8787
    }

"""

if needle not in text:
    raise SystemExit("No se encontró la ruta catch-all esperada; no se modifica Caddyfile.")

text = text.replace(needle, insert + needle, 1)
p.write_text(text)
PY
fi

caddy validate --config "$CADDY"

systemctl reload caddy

sleep 1

curl -fsS https://cen-tral.duckdns.org/android-bridge/api/status >"$APP/data/caddy_status.json"

cat >"$APP/data/public_url.txt" <<'EOF'
ANDROID_BRIDGE_CADDY_READY
url=https://cen-tral.duckdns.org/android-bridge/
api=https://cen-tral.duckdns.org/android-bridge/api/status
EOF

echo "ANDROID_BRIDGE_CADDY_READY"
