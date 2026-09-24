#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/media-xuper-real-payload-scan-v2.txt"
BASE="/home/ubuntu/Central"
mkdir -p /var/lib/conector
: > "$OUT"

echo "MEDIA_XUPER_REAL_PAYLOAD_SCAN_V2" >> "$OUT"
echo "timestamp=$(date -Is)" >> "$OUT"

PROJECTS=(
  "$BASE/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef"
  "$BASE/projects/20260923-131847-xuper-20tv-204-99-2-20-para-20tv-20gratis-20clon-8adb13"
  "$BASE/projects/20260923-140402-xuper-amigonly-2-0-apk-acc315"
)

TOTAL=0
VALID=0
CANDIDATES=0

for P in "${PROJECTS[@]}"; do
  [ -d "$P" ] || continue
  echo >> "$OUT"
  echo "PROJECT=$P" >> "$OUT"

  while IFS= read -r -d '' f; do
    TOTAL=$((TOTAL+1))

    case "$f" in
      */fixtures/*|*/fixture/*|*fixture*.json|*/test/*|*/tests/*|*/android-audit/decoded/*) continue ;;
    esac

    # Fast prefilter: only JSON files that visibly contain Xuper catalog keys.
    if ! grep -aqE '"(contentId|assetList|simpleProgramList|episodeList|channelCode|liveAddressList|programList)"' "$f"; then
      continue
    fi

    SUMMARY="$(python3 - "$f" <<'PY'
import json,sys,os
p=sys.argv[1]
try:
    with open(p,"r",encoding="utf-8",errors="strict") as fh:
        obj=json.load(fh)
except Exception:
    print("invalid")
    raise SystemExit(0)

def ks(o):
    return set(o.keys()) if isinstance(o,dict) else set()

score=0
kind=set()
sample=set()
nodes=[]

if isinstance(obj,dict):
    nodes.append(obj)
    for k in ("data","result","payload"):
        v=obj.get(k)
        if isinstance(v,dict):
            nodes.append(v)
        elif isinstance(v,list) and v and isinstance(v[0],dict):
            nodes.append(v[0])
elif isinstance(obj,list) and obj and isinstance(obj[0],dict):
    nodes.append(obj[0])

for x in nodes:
    k=ks(x)
    sample |= k
    if k & {"assetList","simpleProgramList","episodeList","programContentId","programType","contentType"}:
        score += 2; kind.add("vod")
    if k & {"channelCode","channelNumber","liveAddressList","programList"}:
        score += 2; kind.add("live")
    if k & {"contentId","name","description","posterList"}:
        score += 1

print("score=%d|kind=%s|size=%d|keys=%s" % (
    score,
    ",".join(sorted(kind)) or "unknown",
    os.path.getsize(p),
    ",".join(sorted(sample)[:30])
))
PY
)"

    [ "$SUMMARY" = "invalid" ] && continue
    VALID=$((VALID+1))
    SCORE="$(printf '%s' "$SUMMARY" | sed -n 's/^score=\([0-9][0-9]*\).*/\1/p')"
    if [ "${SCORE:-0}" -ge 2 ]; then
      CANDIDATES=$((CANDIDATES+1))
      echo "CANDIDATE=$f|$SUMMARY" >> "$OUT"
    fi

  done < <(
    find "$P"       -type d \( -path '*/android-audit/decoded' -o -path '*/node_modules' -o -path '*/.git' \) -prune -o       -type f \( -iname '*.json' -o -iname '*.jsonl' \) -size -10M -print0 2>/dev/null
  )
done

echo >> "$OUT"
echo "json_files_scanned=$TOTAL" >> "$OUT"
echo "valid_prefiltered_json=$VALID" >> "$OUT"
echo "xuper_like_candidates=$CANDIDATES" >> "$OUT"
echo "INBOX=/home/ubuntu/Central/media_center/inbox/xuper" >> "$OUT"
echo "NOTE=scan only; nothing imported" >> "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-xuper-real-payload-scan-v2.txt" || true
fi

echo "MEDIA_XUPER_REAL_PAYLOAD_SCAN_V2_READY"
