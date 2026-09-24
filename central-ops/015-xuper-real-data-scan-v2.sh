#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/xuper-real-data-scan.txt"
mkdir -p /var/lib/conector
ROOTS=(/home/ubuntu/Central /home/ubuntu/.cache /home/ubuntu/.local/share /srv/apps)

{
  echo "XUPER_REAL_DATA_SCAN_V2"
  echo "generated_at=$(date -Is)"
  echo

  echo "[CANDIDATE_FILES]"
  find "${ROOTS[@]}" -xdev -type f \( -iname "*.json" -o -iname "*.jsonl" -o -iname "*.db" -o -iname "*.sqlite" -o -iname "*.sqlite3" -o -iname "*.xml" -o -iname "*.txt" \) 2>/dev/null \
    | grep -Ei 'xuper|vod|catalog|content|asset|movie|series|episode|channel|epg|search|favorite|history|cache' \
    | head -n 800 || true

  echo
  echo "[FILES_WITH_CONTENTID_OR_PROGRAMTYPE]"
  grep -RIlE --include="*.json" --include="*.jsonl" --include="*.txt" --include="*.xml" --include="*.log" \
    'contentId|programType|simpleProgramList|episodeList|posterList|channelCode' "${ROOTS[@]}" 2>/dev/null \
    | head -n 500 || true

  echo
  echo "[SQLITE_DATABASES]"
  find "${ROOTS[@]}" -xdev -type f \( -iname "*.db" -o -iname "*.sqlite" -o -iname "*.sqlite3" \) -print 2>/dev/null \
    | head -n 300 || true

  echo
  echo "[SMALL_SAFE_SAMPLES]"
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$sz" -le 1048576 ]; then
      if grep -qE 'contentId|programType|simpleProgramList|episodeList|posterList|channelCode' "$f" 2>/dev/null; then
        echo "--- FILE: $f SIZE=$sz"
        sed -n '1,80p' "$f" \
          | sed -E 's#(token|authorization|auth|license|password|secret|cookie)(["=: ]+)[^, }]+#\1\2<REDACTED>#Ig' \
          | head -n 80
      fi
    fi
  done < <(
    grep -RIlE --include="*.json" --include="*.jsonl" --include="*.txt" \
      'contentId|programType|simpleProgramList|episodeList|posterList|channelCode' "${ROOTS[@]}" 2>/dev/null \
      | head -n 80 || true
  )
} >"$OUT"

chmod 600 "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-real-data-scan.txt" || true
fi

echo "XUPER_REAL_DATA_SCAN_READY"
