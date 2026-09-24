#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/media-xuper-cache-scan.txt"
BASE="/home/ubuntu/Central"
mkdir -p /var/lib/conector
: > "$OUT"

echo "MEDIA_XUPER_CACHE_SCAN" >> "$OUT"
echo "timestamp=$(date -Is)" >> "$OUT"

PROJECTS=(
  "$BASE/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef"
  "$BASE/projects/20260923-131847-xuper-20tv-204-99-2-20-para-20tv-20gratis-20clon-8adb13"
  "$BASE/projects/20260923-140402-xuper-amigonly-2-0-apk-acc315"
)

FILES=0
SQLITE=0
LIKELY=0

for P in "${PROJECTS[@]}"; do
  [ -d "$P" ] || continue
  echo >> "$OUT"
  echo "PROJECT=$P" >> "$OUT"

  while IFS= read -r -d '' f; do
    FILES=$((FILES+1))
    MIME="$(file -b "$f" 2>/dev/null || true)"
    if printf '%s' "$MIME" | grep -qi 'SQLite'; then
      SQLITE=$((SQLITE+1))
      echo "SQLITE=$f|$MIME" >> "$OUT"

      if command -v sqlite3 >/dev/null 2>&1; then
        TABLES="$(sqlite3 "$f" ".tables" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' || true)"
        echo "TABLES=$TABLES" >> "$OUT"
        if printf '%s' "$TABLES" | grep -qiE 'content|program|channel|episode|asset|vod|live|media|poster'; then
          LIKELY=$((LIKELY+1))
          echo "LIKELY_MEDIA_DB=$f" >> "$OUT"
        fi
      fi
    fi
  done < <(
    find "$P"       -type d \( -path '*/android-audit/decoded' -o -path '*/node_modules' -o -path '*/.git' \) -prune -o       -type f \( -iname '*.db' -o -iname '*.sqlite' -o -iname '*.sqlite3' -o -iname '*.realm' -o -iname '*.cache' \)       -size -50M -print0 2>/dev/null
  )
done

echo >> "$OUT"
echo "candidate_files=$FILES" >> "$OUT"
echo "sqlite_files=$SQLITE" >> "$OUT"
echo "likely_media_databases=$LIKELY" >> "$OUT"
echo "NOTE=read-only scan; nothing imported" >> "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-xuper-cache-scan.txt" || true
fi

echo "MEDIA_XUPER_CACHE_SCAN_READY"
