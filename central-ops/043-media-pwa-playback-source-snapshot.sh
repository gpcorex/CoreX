#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/media-pwa-playback-source-snapshot.txt"
BASE="/home/ubuntu/Central/media_center"
SERVICE="$BASE/video/catalog_service.py"
PWA="$BASE/pwa/index.html"

mkdir -p /var/lib/conector
: > "$OUT"

echo "MEDIA_PWA_PLAYBACK_SOURCE_SNAPSHOT" >> "$OUT"
echo "timestamp=$(date -Is)" >> "$OUT"

echo >> "$OUT"
echo "=== catalog_service.py ===" >> "$OUT"
if [ -f "$SERVICE" ]; then
  sed -n '1,260p' "$SERVICE" >> "$OUT"
else
  echo "MISSING=$SERVICE" >> "$OUT"
fi

echo >> "$OUT"
echo "=== pwa index relevant ===" >> "$OUT"
if [ -f "$PWA" ]; then
  sed -n '220,420p' "$PWA" >> "$OUT"
else
  echo "MISSING=$PWA" >> "$OUT"
fi

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-pwa-playback-source-snapshot.txt" || true
fi

echo "MEDIA_PWA_PLAYBACK_SOURCE_SNAPSHOT_READY"
