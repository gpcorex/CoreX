#!/usr/bin/env bash
set -euo pipefail

echo "=== REMOVE RESIDUAL ANDROID BASE SERVICE ==="
systemctl disable --now android-bridge.service 2>/dev/null || true
pkill -TERM -f '/srv/apps/android-bridge/server.py' 2>/dev/null || true
sleep 1
pkill -KILL -f '/srv/apps/android-bridge/server.py' 2>/dev/null || true
rm -f /etc/systemd/system/android-bridge.service
systemctl daemon-reload
systemctl reset-failed android-bridge.service 2>/dev/null || true

echo "=== VERIFY ==="
systemctl is-active android-bridge.service 2>/dev/null || true
pgrep -af '/srv/apps/android-bridge/server.py' || true
if ss -ltnp | grep -q ':8787\b'; then
  echo "ERROR_PORT_8787_STILL_LISTENING"
  ss -ltnp | grep ':8787\b' || true
  exit 1
fi
echo "PORT_8787_FREE"
free -h
uptime
echo ANDROID_BRIDGE_FULLY_REMOVED
