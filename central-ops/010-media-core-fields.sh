#!/usr/bin/env bash
set -euo pipefail
OUT="/var/lib/conector/media-core-fields.txt"
mkdir -p /var/lib/conector
ROOT="/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef/work/android-audit/decoded"
{
  echo "MEDIA_CORE_FIELDS_V1"
  echo "generated_at=$(date -Is)"
  echo
  for rel in \
    smali/com/request/result/MovieList.smali \
    smali/com/request/result/ContentList.smali \
    smali/com/request/result/SearchItem.smali \
    smali/com/request/result/SimpleProgramList.smali \
    smali/com/request/result/GetHomeResult.smali \
    smali/com/request/result/GetColumnContentsResult.smali \
    smali/com/request/result/GetColumnContentsResultData.smali \
    smali/com/request/result/GetRecommendsResultData.smali \
    smali/com/request/result/AssetList.smali \
    smali/com/request/result/ThumbnailResult.smali \
    smali/com/request/result/FavoriteList.smali \
    smali/com/request/result/GetFavoritesResult.smali \
    smali/com/request/result/FilterInfo.smali \
    smali/com/request/result/Item.smali \
    smali/com/request/result/Channel.smali \
    smali/com/request/result/EpgResult.smali \
    smali/com/request/result/StartPlayLiveResult.smali \
    smali/com/request/result/StartPlayBTVResult.smali \
    smali/com/request/result/UrlListBeanResult.smali \
    smali/com/request/result/PcdnMediaInfoResult.smali \
    smali_classes3/com/titan/ranger/bean/Media.smali \
    smali_classes3/com/titan/ranger/bean/Program.smali \
    smali_classes3/com/titan/ranger/bean/MediaFile.smali \
    smali_classes3/com/titans/entity/PlayInfo.smali \
    smali_classes3/com/titans/entity/ProgramInfo.smali \
    smali_classes3/com/titans/entity/Sources.smali
  do
    f="$ROOT/$rel"
    [ -f "$f" ] || continue
    echo "=== $rel ==="
    echo "[FIELDS]"
    grep -E '^\.field ' "$f" 2>/dev/null | head -n 120
    echo "[CONST_STRINGS]"
    grep -E 'const-string ' "$f" 2>/dev/null | head -n 120
    echo "[METHODS]"
    grep -E '^\.method ' "$f" 2>/dev/null | head -n 120
    echo
  done
  echo "[VOD_DOMAIN_CLASSES]"
  find "$ROOT" -type f -name '*.smali' | grep -E '/com/(vod|request/result|titans|titan/ranger)/' | grep -Ei 'movie|series|season|episode|program|asset|content|detail|search|source|play|url|channel|epg' | sed "s#^$ROOT/##" | sort -u | head -n 500
} >"$OUT"
chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-core-fields.txt" || true
fi
echo "MEDIA_CORE_FIELDS_READY"
