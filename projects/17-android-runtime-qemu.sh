#!/usr/bin/env bash
set -euo pipefail

APP="/srv/apps/android-bridge"
RT="$APP/runtime"
DATA="$APP/data"
ISO="$RT/android-x86_64-9.0-r2.iso"
DISK="$RT/android-data.qcow2"
SHA256_EXPECTED="f7eb8fc56f29ad5432335dc054183acf086c539f3990f0b6e9ff58bd6df4604e"
URL="https://downloads.sourceforge.net/project/android-x86/Release%209.0/android-x86_64-9.0-r2.iso"

mkdir -p "$RT" "$DATA"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y qemu-system-x86 qemu-utils

if [ ! -f "$ISO" ]; then
  tmp="$ISO.part"
  rm -f "$tmp"
  curl -fL --retry 3 --retry-delay 3 -o "$tmp" "$URL"
  echo "$SHA256_EXPECTED  $tmp" | sha256sum -c -
  mv "$tmp" "$ISO"
else
  echo "$SHA256_EXPECTED  $ISO" | sha256sum -c -
fi

if [ ! -f "$DISK" ]; then
  qemu-img create -f qcow2 "$DISK" 4G
fi

chown -R ubuntu:ubuntu "$RT"

cat >/etc/systemd/system/android-runtime.service <<'UNIT'
[Unit]
Description=Android Bridge Android-x86 runtime
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/srv/apps/android-bridge/runtime
ExecStart=/usr/bin/qemu-system-x86_64 \
  -name android-bridge \
  -enable-kvm \
  -cpu host \
  -smp 1 \
  -m 512 \
  -machine pc,accel=kvm \
  -boot d \
  -cdrom /srv/apps/android-bridge/runtime/android-x86_64-9.0-r2.iso \
  -drive file=/srv/apps/android-bridge/runtime/android-data.qcow2,if=ide,format=qcow2 \
  -vga std \
  -device e1000,netdev=n1 \
  -netdev user,id=n1 \
  -display vnc=127.0.0.1:1 \
  -monitor unix:/srv/apps/android-bridge/runtime/qemu-monitor.sock,server,nowait \
  -no-reboot
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now android-runtime.service

sleep 8

{
  echo "ANDROID_RUNTIME_QEMU"
  echo "date=$(date -Is)"
  echo
  echo "[SERVICE]"
  systemctl is-active android-runtime.service || true
  echo
  echo "[PROCESS]"
  pgrep -a qemu-system-x86_64 || true
  echo
  echo "[VNC]"
  ss -ltnp | grep ':5901 ' || true
  echo
  echo "[MEM]"
  free -m
  echo
  echo "[LOAD]"
  uptime
  echo
  echo "[ISO]"
  sha256sum "$ISO"
} >"$DATA/runtime-qemu.txt"

echo "ANDROID_RUNTIME_QEMU_READY"
