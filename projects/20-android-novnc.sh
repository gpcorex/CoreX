#!/usr/bin/env bash
set -euo pipefail

APP="/srv/apps/android-bridge"
OUT="$APP/data/novnc.txt"
CADDY="/etc/caddy/Caddyfile"
BACKUP="/etc/caddy/Caddyfile.before-android-novnc"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y novnc websockify

cat >/etc/systemd/system/android-novnc.service <<'UNIT'
[Unit]
Description=Android Bridge noVNC proxy
After=network-online.target android-runtime.service
Wants=network-online.target
Requires=android-runtime.service

[Service]
Type=simple
ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ 127.0.0.1:6080 127.0.0.1:5901
Restart=always
RestartSec=2
User=ubuntu
Group=ubuntu

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now android-novnc.service

cp -a "$CADDY" "$BACKUP"

if ! grep -q 'route /android-view/\*' "$CADDY"; then
python3 - <<'PY'
from pathlib import Path
p = Path("/etc/caddy/Caddyfile")
text = p.read_text()

needle = """    route {
        reverse_proxy 127.0.0.1:8090
    }
"""

insert = """    route /android-view/* {
        uri strip_prefix /android-view
        reverse_proxy 127.0.0.1:6080
    }

"""

if needle not in text:
    raise SystemExit("No se encontró la ruta principal esperada; no se modifica Caddy.")
text = text.replace(needle, insert + needle, 1)
p.write_text(text)
PY
fi

caddy validate --config "$CADDY"
systemctl reload caddy

sleep 3

{
  echo "ANDROID_NOVNC_READY"
  echo "date=$(date -Is)"
  echo
  echo "[NOVNC_SERVICE]"
  systemctl is-active android-novnc.service || true
  echo
  echo "[PORT6080]"
  ss -ltnp | grep ':6080 ' || true
  echo
  echo "[QEMU]"
  systemctl is-active android-runtime.service || true
  echo
  echo "[URL]"
  echo "https://cen-tral.duckdns.org/android-view/vnc.html?path=android-view/websockify&autoconnect=true&resize=scale"
} >"$OUT"

echo "ANDROID_NOVNC_READY"
