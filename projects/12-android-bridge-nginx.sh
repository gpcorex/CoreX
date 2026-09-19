#!/usr/bin/env bash
set -euo pipefail

APP="/srv/apps/android-bridge"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx

cat >/etc/nginx/sites-available/android-bridge <<'NGINX'
server {
    listen 80;
    server_name _;

    location /android-bridge/ {
        proxy_pass http://127.0.0.1:8787/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/android-bridge /etc/nginx/sites-enabled/android-bridge
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable --now nginx
systemctl restart nginx

curl -fsS http://127.0.0.1/android-bridge/api/status >"$APP/data/public_status.json"

IP="$(hostname -I | awk '{print $1}')"
cat >"$APP/data/access.txt" <<EOF
ANDROID_BRIDGE_PUBLIC_READY
local_url=http://$IP/android-bridge/
api_url=http://$IP/android-bridge/api/status
EOF

echo "ANDROID_BRIDGE_PUBLIC_READY"
