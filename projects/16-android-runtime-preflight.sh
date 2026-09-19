#!/usr/bin/env bash
set -euo pipefail

OUT="/srv/apps/android-bridge/data/runtime-preflight.txt"
mkdir -p "$(dirname "$OUT")"

{
  echo "ANDROID_RUNTIME_PREFLIGHT"
  echo "date=$(date -Is)"
  echo
  echo "[MEM]"
  free -m
  echo
  echo "[SWAP]"
  swapon --show || true
  echo
  echo "[KVM]"
  ls -l /dev/kvm 2>/dev/null || true
  echo
  echo "[QEMU]"
  command -v qemu-system-x86_64 || true
  qemu-system-x86_64 --version 2>/dev/null | head -1 || true
  echo
  echo "[LIBVIRT]"
  systemctl is-active libvirtd 2>/dev/null || true
  echo
  echo "[LOAD]"
  uptime
} >"$OUT"

echo "ANDROID_RUNTIME_PREFLIGHT_OK"
