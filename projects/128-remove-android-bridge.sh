#!/usr/bin/env bash
set -euo pipefail

APP=/srv/apps/android-bridge
CADDY=/etc/caddy/Caddyfile
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/android-bridge-removed-$STAMP

echo "=== 1. BACKUP CONFIG ONLY ==="
mkdir -p "$BACKUP"
[ -f "$CADDY" ] && cp -a "$CADDY" "$BACKUP/Caddyfile"
for f in /etc/systemd/system/android-runtime.service /etc/systemd/system/android-novnc.service; do
  [ -f "$f" ] && cp -a "$f" "$BACKUP/"
done

echo "=== 2. STOP + DISABLE ANDROID SERVICES ==="
systemctl disable --now android-novnc.service 2>/dev/null || true
systemctl disable --now android-runtime.service 2>/dev/null || true

# Safety net: terminate only the known Android bridge processes if a unit failed to stop cleanly.
pkill -TERM -f 'qemu-system-x86_64 -name android-bridge' 2>/dev/null || true
pkill -TERM -f 'websockify.*127\.0\.0\.1:6080.*127\.0\.0\.1:5901' 2>/dev/null || true
sleep 2
pkill -KILL -f 'qemu-system-x86_64 -name android-bridge' 2>/dev/null || true
pkill -KILL -f 'websockify.*127\.0\.0\.1:6080.*127\.0\.0\.1:5901' 2>/dev/null || true

echo "=== 3. REMOVE SERVICE UNITS ==="
rm -f /etc/systemd/system/android-runtime.service
rm -f /etc/systemd/system/android-novnc.service
systemctl daemon-reload
systemctl reset-failed android-runtime.service android-novnc.service 2>/dev/null || true

echo "=== 4. REMOVE CADDY ROUTES ==="
if [ -f "$CADDY" ]; then
python3 - <<'PY'
from pathlib import Path
p=Path("/etc/caddy/Caddyfile")
s=p.read_text()
blocks=[
'''    route /android-bridge/* {
        uri strip_prefix /android-bridge
        reverse_proxy 127.0.0.1:8787
    }

''',
'''    route /android-view/* {
        uri strip_prefix /android-view
        reverse_proxy 127.0.0.1:6080
    }

''',
]
for b in blocks:
    s=s.replace(b,'')
p.write_text(s)
PY
  caddy validate --config "$CADDY"
  systemctl reload caddy
fi

echo "=== 5. REMOVE ANDROID BRIDGE FILES ==="
rm -rf "$APP"
rm -f /srv/apps/PUENTE_OK.txt

echo "=== 6. REMOVE LEGACY STATUS/RECOVERY ARTIFACTS ==="
rm -f /etc/caddy/Caddyfile.before-android-bridge
rm -f /etc/caddy/Caddyfile.before-android-novnc

echo "=== 7. VERIFY ==="
echo "-- services --"
systemctl is-active android-runtime.service 2>/dev/null || true
systemctl is-active android-novnc.service 2>/dev/null || true
echo "-- processes --"
pgrep -af 'qemu-system-x86_64.*android-bridge|websockify.*6080.*5901' || true
echo "-- ports --"
ss -ltnp | grep -E ':(5901|6080|8787)\b' || true
echo "-- app dir --"
if [ -e "$APP" ]; then
  echo "ERROR_ANDROID_DIR_STILL_EXISTS"
  exit 1
else
  echo "ANDROID_DIR_REMOVED"
fi
echo "-- Caddy routes --"
if grep -nE '/android-bridge|/android-view' "$CADDY" 2>/dev/null; then
  echo "ERROR_ANDROID_CADDY_ROUTE_STILL_PRESENT"
  exit 1
else
  echo "ANDROID_CADDY_ROUTES_REMOVED"
fi
echo "-- memory/load --"
free -h
uptime

echo "ANDROID_BRIDGE_REMOVED"
echo "config_backup=$BACKUP"
