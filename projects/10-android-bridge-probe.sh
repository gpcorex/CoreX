#!/usr/bin/env bash
set -euo pipefail

BASE="/srv/apps/android-bridge"
mkdir -p "$BASE"

{
  echo "ANDROID_BRIDGE_PROBE"
  echo "date=$(date -Is)"
  echo "host=$(hostname)"
  echo "arch=$(uname -m)"
  echo "cpus=$(nproc)"
  echo "kernel=$(uname -r)"
  echo
  echo "[MEMORY]"
  free -h
  echo
  echo "[DISK]"
  df -h /
  echo
  echo "[KVM]"
  if [ -e /dev/kvm ]; then
    ls -l /dev/kvm
    echo "KVM=YES"
  else
    echo "KVM=NO"
  fi
  echo
  echo "[BINDER]"
  grep -E 'binder|ashmem' /proc/filesystems || true
  ls -la /dev/binder* /dev/ashmem 2>/dev/null || true
  echo
  echo "[VIRTUALIZATION]"
  lscpu | grep -E 'Architecture|Virtualization|Hypervisor|Model name|CPU\(s\)' || true
  echo
  echo "[DOCKER]"
  if command -v docker >/dev/null 2>&1; then
    docker --version
  else
    echo "DOCKER=NO"
  fi
} > "$BASE/diagnostico.txt"

echo "ANDROID_BRIDGE_PROBE_OK"
