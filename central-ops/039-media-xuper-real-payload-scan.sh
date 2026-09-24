#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/media-xuper-real-payload-scan.txt"
BASE="/home/ubuntu/Central"
TMP="/tmp/media-xuper-real-payload-scan"
mkdir -p "$TMP" /var/lib/conector
: > "$OUT"

echo "MEDIA_XUPER_REAL_PAYLOAD_SCAN" >> "$OUT"
echo "timestamp=$(date -Is)" >> "$OUT"

PROJECTS=(
  "$BASE/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef"
  "$BASE/projects/20260923-131847-xuper-20tv-204-99-2-20-para-20tv-20gratis-20clon-8adb13"
  "$BASE/projects/20260923-140402-xuper-amigonly-2-0-apk-acc315"
)

TOTAL=0
JSONS=0
CANDIDATES=0

for P in "${PROJECTS[@]}"; do
  [ -d "$P" ] || continue
  echo >> "$OUT"
  echo "PROJECT=$P" >> "$OUT"

  while IFS= read -r -d '' f; do
    TOTAL=$((TOTAL+1))
    case "$f" in
      */fixtures/*|*/fixture/*|*fixture*.json|*/test/*|*/tests/*) continue ;;
    esac

    if file -b --mime-type "$f" 2>/dev/null | grep -q 'application/json\|text/plain'; then
      if python3 - "$f" <<'PY' >/dev/null 2>&1
import json,sys
with open(sys.argv[1],"rb") as fh:
    json.load(fh)
PY
      then
        JSONS=$((JSONS+1))
        SUMMARY="$(python3 - "$f" <<'PY'
import json,sys,os
p=sys.argv[1]
with open(p,"r",encoding="utf-8",errors="ignore") as fh:
    obj=json.load(fh)

def keys(o):
    return set(o.keys()) if isinstance(o,dict) else set()

score=0
kind=[]
sample_keys=set()
if isinstance(obj,dict):
    sample_keys |= keys(obj)
    pools=[obj]
    for k in ("data","result","payload"):
        if isinstance(obj.get(k),dict):
            pools.append(obj[k])
        elif isinstance(obj.get(k),list) and obj[k] and isinstance(obj[k][0],dict):
            pools.append(obj[k][0])
    for x in pools:
        ks=keys(x)
        sample_keys |= ks
        if ks & {"assetList","simpleProgramList","episodeList","programContentId","programType","contentType"}:
            score += 2; kind.append("vod")
        if ks & {"channelCode","channelNumber","liveAddressList","programList"}:
            score += 2; kind.append("live")
        if ks & {"contentId","name","description","posterList"}:
            score += 1
elif isinstance(obj,list) and obj and isinstance(obj[0],dict):
    sample_keys |= keys(obj[0])
    ks=keys(obj[0])
    if ks & {"assetList","simpleProgramList","episodeList","programType","contentType"}:
        score += 2; kind.append("vod")
    if ks & {"channelCode","channelNumber","liveAddressList","programList"}:
        score += 2; kind.append("live")
    if ks & {"contentId","name","description","posterList"}:
        score += 1

print(f"score={score}|kind={','.join(sorted(set(kind))) or 'unknown'}|size={os.path.getsize(p)}|keys={','.join(sorted(sample_keys)[:30])}")
PY
)"
        SCORE="$(printf '%s' "$SUMMARY" | sed -n 's/^score=\([0-9][0-9]*\).*/\1/p')"
        if [ "${SCORE:-0}" -ge 2 ]; then
          CANDIDATES=$((CANDIDATES+1))
          echo "CANDIDATE=$f|$SUMMARY" >> "$OUT"
        fi
      fi
    fi
  done < <(find "$P" -type f -size -5M -print0 2>/dev/null)
done

echo >> "$OUT"
echo "scanned_files=$TOTAL" >> "$OUT"
echo "valid_json=$JSONS" >> "$OUT"
echo "xuper_like_candidates=$CANDIDATES" >> "$OUT"

echo >> "$OUT"
echo "INBOX=/home/ubuntu/Central/media_center/inbox/xuper" >> "$OUT"
echo "NOTE=no files were imported; scan only" >> "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-xuper-real-payload-scan.txt" || true
fi

echo "MEDIA_XUPER_REAL_PAYLOAD_SCAN_READY"
