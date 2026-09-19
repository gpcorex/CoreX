#!/usr/bin/env bash
set -euo pipefail

APP="/srv/apps/android-bridge"
mkdir -p "$APP/data"

# No tocar el puerto 80: ya está ocupado por otro servicio.
# Android Bridge se publica directamente por 8787.
if grep -q '127.0.0.1' "$APP/server.py"; then
  sed -i 's/ThreadingHTTPServer(("127\.0\.0\.1", PORT)/ThreadingHTTPServer(("0.0.0.0", PORT)/' "$APP/server.py"
fi

systemctl restart android-bridge.service
sleep 1

curl -fsS http://127.0.0.1:8787/api/status >"$APP/data/public_status.json"

# Limpiar la configuración nginx fallida de Android Bridge, sin tocar otros sitios.
rm -f /etc/nginx/sites-enabled/android-bridge 2>/dev/null || true
rm -f /etc/nginx/sites-available/android-bridge 2>/dev/null || true

cat >"$APP/data/access.txt" <<'EOF'
ANDROID_BRIDGE_PUBLIC_READY
port=8787
path=/
api_path=/api/status
EOF

echo "ANDROID_BRIDGE_PUBLIC_READY"
