#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/media-model-map.txt"
mkdir -p /var/lib/conector

{
  echo "MEDIA_MODEL_MAP_V1"
  echo "generated_at=$(date -Is)"
  echo

  for d in /home/ubuntu/Central/projects/*xuper* /home/ubuntu/Central/projects/*crunchy*; do
    [ -d "$d/work/android-audit/decoded" ] || continue
    echo "=== PROJECT $(basename "$d") ==="

    echo "[MODEL_LIKE_FILES]"
    find "$d/work/android-audit/decoded" -type f -name '*.smali' \
      | grep -Ei '/(model|bean|entity|dto|response|request|data)/|Movie|Series|Season|Episode|Vod|Anime|Detail|Search|Play' \
      | sed "s#^$d/work/android-audit/decoded/##" \
      | head -n 500

    echo "[HTTP_ENDPOINT_STRINGS]"
    grep -RhoE --include='*.smali' 'https?://[^"[:space:]]+|/[A-Za-z0-9._~:/?#\[\]@!$&()*+,;=%-]{6,}' \
      "$d/work/android-audit/decoded" 2>/dev/null \
      | grep -Ei 'movie|series|season|episode|detail|search|vod|anime|stream|play|subtitle|favorite|history|catalog' \
      | sort -u | head -n 300

    echo "[FIELD_NAMES_FROM_RELEVANT_CLASSES]"
    files=$(find "$d/work/android-audit/decoded" -type f -name '*.smali' \
      | grep -Ei '/(model|bean|entity|dto|response|request|data)/|Movie|Series|Season|Episode|Vod|Anime|Detail|Search' \
      | head -n 220 || true)
    if [ -n "$files" ]; then
      while IFS= read -r f; do
        rel="\${f#$d/work/android-audit/decoded/}"
        echo "--- $rel"
        grep -E '^\.field ' "$f" 2>/dev/null | head -n 80
      done <<< "$files"
    fi
    echo
  done
} >"$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-model-map.txt" || true
fi

echo "MEDIA_MODEL_MAP_READY"
