#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/media-pwa-playback-readiness.txt"
BASE="/home/ubuntu/Central/media_center"
DB="$BASE/video/catalog.db"
SERVICE="$BASE/video/catalog_service.py"
PWA="$BASE/pwa/index.html"

mkdir -p /var/lib/conector
: > "$OUT"

echo "MEDIA_PWA_PLAYBACK_READINESS" >> "$OUT"
echo "timestamp=$(date -Is)" >> "$OUT"

echo >> "$OUT"
echo "=== playback_source schema ===" >> "$OUT"
if [ -f "$DB" ]; then
  sqlite3 "$DB" ".schema playback_source" >> "$OUT" 2>&1 || true
  echo >> "$OUT"
  echo "playback_source_count=$(sqlite3 "$DB" 'select count(*) from playback_source;' 2>/dev/null || echo ERR)" >> "$OUT"
else
  echo "DB_MISSING=$DB" >> "$OUT"
fi

echo >> "$OUT"
echo "=== catalog service playback references ===" >> "$OUT"
if [ -f "$SERVICE" ]; then
  grep -nEi 'playback|source|video/item|live/channel' "$SERVICE" | head -160 >> "$OUT" || true
else
  echo "SERVICE_MISSING=$SERVICE" >> "$OUT"
fi

echo >> "$OUT"
echo "=== pwa player/detail references ===" >> "$OUT"
if [ -f "$PWA" ]; then
  grep -nEi '<video|playback|reproduc|detalle|detail|video/item|live/channel' "$PWA" | head -160 >> "$OUT" || true
else
  echo "PWA_MISSING=$PWA" >> "$OUT"
fi

echo >> "$OUT"
echo "=== local api health ===" >> "$OUT"
curl -fsS http://127.0.0.1:8092/health >> "$OUT" 2>&1 || true
echo >> "$OUT"

echo >> "$OUT"
echo "=== first item sample ===" >> "$OUT"
curl -fsS 'http://127.0.0.1:8092/video/items?limit=1' >> "$OUT" 2>&1 || true
echo >> "$OUT"

echo >> "$OUT"
echo "NOTE=read-only diagnostic; no catalog or PWA changes" >> "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-pwa-playback-readiness.txt" || true
fi

echo "MEDIA_PWA_PLAYBACK_READINESS_READY"
