#!/usr/bin/env bash
set -euo pipefail
PWA="/home/ubuntu/Central/media_center/pwa/index.html"
OUT="/var/lib/conector/media-pwa-click-debug.txt"
mkdir -p /var/lib/conector
{
  echo "MEDIA_PWA_CLICK_DEBUG"
  echo "timestamp=$(date -Is)"
  echo
  echo "=== card/openPlayable/annotate markers ==="
  grep -nE 'function card|data-item-id|openPlayable|annotatePlayableCards|addEventListener\("click"|load\(\)' "$PWA" || true
  echo
  echo "=== card function context ==="
  grep -n -A8 -B2 'function card' "$PWA" || true
  echo
  echo "=== openPlayable context ==="
  grep -n -A55 -B5 'async function openPlayable' "$PWA" || true
  echo
  echo "=== annotate context ==="
  grep -n -A20 -B5 'function annotatePlayableCards' "$PWA" || true
} > "$OUT"
chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-pwa-click-debug.txt" || true
fi
cat "$OUT"
