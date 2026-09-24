#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/media-catalog-source-scan.txt"
mkdir -p /var/lib/conector

{
  echo "MEDIA_CATALOG_SOURCE_SCAN_V1"
  echo "generated_at=$(date -Is)"
  echo

  echo "[PROJECTS]"
  find /home/ubuntu/Central/projects -maxdepth 1 -mindepth 1 -type d \
    \( -iname '*xuper*' -o -iname '*crunchy*' \) -printf '%f\n' 2>/dev/null | sort
  echo

  echo "[COMPONENT_PACKAGES]"
  for d in /home/ubuntu/Central/projects/*xuper* /home/ubuntu/Central/projects/*crunchy*; do
    [ -d "$d/work/component-packages" ] || continue
    echo "PROJECT=$(basename "$d")"
    find "$d/work/component-packages" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort
    echo
  done

  echo "[SUMMARY_FILES]"
  find /home/ubuntu/Central/projects -type f \
    \( -iname '*summary*' -o -iname '*report*' -o -iname '*manifest*' -o -iname '*package*json' \
       -o -iname '*inventory*' -o -iname '*component*json' \) \
    | grep -Ei 'xuper|crunchy' | sort | head -n 300
  echo

  echo "[POSSIBLE_CATALOG_ENDPOINTS_AND_MODELS]"
  grep -RInE --include='*.smali' --include='*.json' --include='*.xml' \
    'movie|series|season|episode|catalog|search|detail|vod|anime|playback|stream|subtitle|favorite|history' \
    /home/ubuntu/Central/projects/*xuper*/work /home/ubuntu/Central/projects/*crunchy*/work 2>/dev/null \
    | grep -v '/res/values' | head -n 1200
  echo

  echo "[LARGEST_STRUCTURED_FILES]"
  find /home/ubuntu/Central/projects -type f \
    \( -iname '*.json' -o -iname '*.db' -o -iname '*.sqlite' -o -iname '*.sqlite3' -o -iname '*.xml' \) \
    | grep -Ei 'xuper|crunchy' \
    | xargs -r du -b 2>/dev/null | sort -nr | head -n 200
} >"$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-catalog-source-scan.txt" || true
fi

echo "MEDIA_CATALOG_SOURCE_SCAN_READY"
