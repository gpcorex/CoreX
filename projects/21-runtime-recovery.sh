#!/usr/bin/env bash
set -euo pipefail

APP="/srv/apps/android-bridge"
OUT="$APP/data/runtime-recovery.txt"
UNIT="/etc/systemd/system/android-runtime.service"

mkdir -p "$APP/data"

{
  echo "ANDROID_RUNTIME_RECOVERY_DIAG"
  echo "date=$(date -Is)"
  echo
  echo "[STATUS_BEFORE]"
  systemctl --no-pager -l status android-runtime.service || true
  echo
  echo "[JOURNAL]"
  journalctl -u android-runtime.service -n 120 --no-pager || true
} >"$OUT"

if [ -f "$UNIT" ]; then
  sed -i 's/^Restart=on-failure$/Restart=always/' "$UNIT"
  if ! grep -q '^RestartSec=' "$UNIT"; then
    sed -i '/^Restart=always$/a RestartSec=5' "$UNIT"
  fi
fi

systemctl daemon-reload
systemctl restart android-runtime.service

sleep 8

{
  echo
  echo "[STATUS_AFTER]"
  systemctl --no-pager -l status android-runtime.service || true
  echo
  echo "[VNC_AFTER]"
  ss -ltnp | grep ':5901 ' || true
  echo
  echo "[MEM_AFTER]"
  free -m
} >>"$OUT"

echo "ANDROID_RUNTIME_RECOVERY_DONE"
