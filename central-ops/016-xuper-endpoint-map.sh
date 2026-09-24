#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/xuper-endpoint-map.txt"
mkdir -p /var/lib/conector

ROOT="/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef/work"
DEOBF="$ROOT/deobfuscation/decoded-strings.json"
DEC="$ROOT/android-audit/decoded"

{
  echo "XUPER_ENDPOINT_MAP_V1"
  echo "generated_at=$(date -Is)"
  echo

  echo "[BASE_URLS_AND_HTTP_STRINGS]"
  if [ -f "$DEOBF" ]; then
    grep -Eo 'https?://[^"[:space:]]+' "$DEOBF" 2>/dev/null | sort -u | head -n 300 || true
  fi
  echo

  echo "[REQUEST_RELATED_CONST_STRINGS]"
  find "$DEC/smali" "$DEC/smali_classes2" "$DEC/smali_classes3" "$DEC/smali_classes4"     -type f -name '*.smali' 2>/dev/null     | grep -Ei '/com/(request|vod|dcs|titans|titan/ranger)/'     | while IFS= read -r f; do
        hits=$(grep -E 'const-string ' "$f" 2>/dev/null           | grep -Ei 'http|/api|/v[0-9]|content|home|column|recommend|search|detail|play|vod|channel|epg|favorite|program|asset|series|episode'           | head -n 80 || true)
        if [ -n "$hits" ]; then
          echo "--- ${f#$DEC/}"
          printf '%s\n' "$hits"
        fi
      done | head -n 2200
  echo

  echo "[LIKELY_NETWORK_CLASSES]"
  find "$DEC" -type f -name '*.smali' 2>/dev/null     | grep -Ei '/com/(request|dcs|vod)/'     | grep -Ei 'api|service|request|retrofit|http|client|url|play|home|search|content|column|channel|epg'     | sed "s#^$DEC/##" | sort -u | head -n 500
} > "$OUT"

chmod 600 "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-endpoint-map.txt" || true
fi

echo "XUPER_ENDPOINT_MAP_READY"
