#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/media-audits-inventory.txt"
BASE="/home/ubuntu/Central/projects"
mkdir -p /var/lib/conector
: > "$OUT"

echo "MEDIA_AUDITS_INVENTORY" >> "$OUT"
echo "timestamp=$(date -Is)" >> "$OUT"

PROJECTS=(
  "$BASE/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef"
  "$BASE/20260923-131847-xuper-20tv-204-99-2-20-para-20tv-20gratis-20clon-8adb13"
  "$BASE/20260923-140402-xuper-amigonly-2-0-apk-acc315"
  "$BASE/20260923-092511-crunchyroll-20v3-112-2-20-premium-apk-ecb4b7"
)

for P in "${PROJECTS[@]}"; do
  echo >> "$OUT"
  if [ ! -d "$P" ]; then
    echo "MISSING_PROJECT=$P" >> "$OUT"
    continue
  fi

  echo "PROJECT=$P" >> "$OUT"
  echo "--- top-level files ---" >> "$OUT"
  find "$P" -maxdepth 2 -type f \(     -iname '*.txt' -o -iname '*.json' -o -iname '*.md' -o -iname '*.html'   \) -printf '%P|%s bytes\n' 2>/dev/null | sort | head -220 >> "$OUT"

  echo "--- audit/result dirs ---" >> "$OUT"
  find "$P" -maxdepth 3 -type d \(     -iname '*audit*' -o -iname '*result*' -o -iname '*report*' -o -iname '*analysis*'   \) -printf '%P\n' 2>/dev/null | sort | head -120 >> "$OUT"
done

echo >> "$OUT"
echo "NOTE=inventory only; no files modified" >> "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-audits-inventory.txt" || true
fi

cat "$OUT"
