#!/usr/bin/env bash
set -euo pipefail

OUT="/srv/apps/android-bridge/data/runtime-diagnose.txt"
mkdir -p "$(dirname "$OUT")"

{
  echo "ANDROID_RUNTIME_DIAGNOSE"
  echo "date=$(date -Is)"
  echo
  echo "[UBUNTU_ID]"
  id ubuntu || true
  echo
  echo "[KVM_DEVICE]"
  ls -l /dev/kvm || true
  echo
  echo "[SERVICE_STATUS]"
  systemctl --no-pager -l status android-runtime.service || true
  echo
  echo "[JOURNAL]"
  journalctl -u android-runtime.service -n 80 --no-pager || true
  echo
  echo "[UNIT]"
  systemctl cat android-runtime.service || true
} >"$OUT"

echo "ANDROID_RUNTIME_DIAGNOSE_OK"
