#!/usr/bin/env bash
set -euo pipefail

APP="/srv/apps/android-bridge"
OUT="$APP/data/runtime-after-kvm-fix.txt"
mkdir -p "$APP/data"

getent group kvm >/dev/null
usermod -aG kvm ubuntu

systemctl daemon-reload
systemctl restart android-runtime.service

sleep 6

{
  echo "ANDROID_RUNTIME_KVM_FIX"
  echo "date=$(date -Is)"
  echo
  echo "[UBUNTU_ID]"
  id ubuntu || true
  echo
  echo "[SERVICE]"
  systemctl --no-pager -l status android-runtime.service || true
  echo
  echo "[PROCESS]"
  pgrep -a qemu-system-x86_64 || true
  echo
  echo "[VNC]"
  ss -ltnp | grep ':5901 ' || true
  echo
  echo "[MEM]"
  free -m
} >"$OUT"

echo "ANDROID_RUNTIME_KVM_FIX_OK"
