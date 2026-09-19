#!/usr/bin/env bash
set -euo pipefail

APP="/srv/apps/android-bridge"
OUT="$APP/data/installer-launch.txt"
MON="$APP/runtime/qemu-monitor.sock"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y socat

systemctl restart android-runtime.service

for i in $(seq 1 20); do
  [ -S "$MON" ] && break
  sleep 1
done

if [ ! -S "$MON" ]; then
  echo "Monitor QEMU no disponible" >"$OUT"
  exit 1
fi

# Esperar a que aparezca el menú de Android-x86.
sleep 2

# Desde "Live CD": bajar dos veces hasta "Installation" y Enter.
{
  echo "sendkey down"
  sleep 0.4
  echo "sendkey down"
  sleep 0.4
  echo "sendkey ret"
} | socat - UNIX-CONNECT:"$MON"

sleep 4

{
  echo "ANDROID_INSTALLER_LAUNCH_SENT"
  echo "date=$(date -Is)"
  echo "runtime=$(systemctl is-active android-runtime.service || true)"
  echo "vnc=$(ss -ltn | grep -c ':5901 ' || true)"
} >"$OUT"

echo "ANDROID_INSTALLER_LAUNCH_SENT"
