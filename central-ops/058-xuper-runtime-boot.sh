#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/xuper-runtime-boot.txt"
PROJECT="/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef"
mkdir -p /var/lib/conector
: > "$OUT"

{
  echo "XUPER_RUNTIME_BOOT"
  echo "timestamp=$(date -Is)"
  echo
  echo "=== RUNTIME SERVICES ==="
  systemctl is-active android-runtime.service 2>&1 || true
  systemctl is-active android-novnc.service 2>&1 || true
  echo
  echo "=== ADB ==="
  command -v adb || true
  adb devices 2>&1 || true
  echo
  echo "=== APK CANDIDATES ==="
  find "$PROJECT" -type f \( -iname '*.apk' -o -iname '*.xapk' \) -printf '%p\n' 2>/dev/null | head -20
  echo
  echo "=== PACKAGE FROM MANIFEST ==="
  MANIFEST="$(find "$PROJECT" -path '*/decoded/AndroidManifest.xml' -print -quit 2>/dev/null || true)"
  echo "manifest=$MANIFEST"
  if [ -n "$MANIFEST" ]; then
    grep -o 'package="[^"]*"' "$MANIFEST" | head -1 || true
  fi
} >> "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-runtime-boot.txt" || true
fi

echo "XUPER_RUNTIME_BOOT_READY"
cat "$OUT"
