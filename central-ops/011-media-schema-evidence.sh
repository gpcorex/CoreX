#!/usr/bin/env bash
set -euo pipefail
OUT="/var/lib/conector/media-schema-evidence.txt"
mkdir -p /var/lib/conector
ROOT="/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef/work/android-audit/decoded"
{
  echo "MEDIA_SCHEMA_EVIDENCE_V1"
  echo "generated_at=$(date -Is)"
  echo
  for rel in \
    smali/com/request/result/AssetList.smali \
    smali/com/request/result/AssetData.smali \
    smali/com/request/result/TotalMovieListItem.smali \
    smali/com/request/result/SameSeasonSeriesBean.smali \
    smali/com/request/result/SeriesSearchResult.smali \
    smali/com/request/result/ProgramSearchResult.smali \
    smali/com/request/result/ResourceSearchResult.smali \
    smali/com/request/result/StartPlayVODResult.smali \
    smali/com/request/result/StartPlayVODResultData.smali \
    smali/com/request/result/StartPlayVODResultDataItem.smali \
    smali/com/request/result/GetPlayUrlResult.smali \
    smali/com/request/result/Channel.smali \
    smali/com/request/result/EpgData.smali \
    smali/com/request/result/StartPlayLiveResultData.smali
  do
    f="$ROOT/$rel"
    [ -f "$f" ] || continue
    echo "=== $rel ==="
    grep -E '^\.field ' "$f" 2>/dev/null || true
    echo
  done
} >"$OUT"
chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-schema-evidence.txt" || true
fi
echo "MEDIA_SCHEMA_EVIDENCE_READY"
