#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/xuper-network-wiring.txt"
mkdir -p /var/lib/conector

ROOT="/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef/work/android-audit/decoded"

{
  echo "XUPER_NETWORK_WIRING_V1"
  echo "generated_at=$(date -Is)"
  echo

  echo "[RETROFIT_HTTP_ANNOTATIONS]"
  grep -RInE --include='*.smali' 'Lretrofit2/http/(GET|POST|PUT|DELETE|PATCH|Url|Body|Query|Field|Path|Header);|retrofit2/http'     "$ROOT" 2>/dev/null     | grep -Ei '/com/(request|dcs|vod|core|interactive)/'     | head -n 1800 || true
  echo

  echo "[REQUEST_API_CLASSES]"
  find "$ROOT" -type f -name '*.smali' 2>/dev/null     | grep -Ei '/com/(request|dcs)/'     | grep -Ei '(api|service|retrofit|http|client|request|url|domain|host|config)'     | sed "s#^$ROOT/##" | sort -u | head -n 700
  echo

  echo "[DOMAIN_AND_URLINFO_CLASSES]"
  for f in     "$ROOT/smali/com/dcs/bean/DomainInfo.smali"     "$ROOT/smali/com/dcs/bean/URLInfo.smali"     "$ROOT/smali/com/dcs/bean/N1Data.smali"     "$ROOT/smali/com/dcs/bean/V1Data.smali"     "$ROOT/smali/com/dcs/bean/V1Bean.smali"
  do
    [ -f "$f" ] || continue
    echo "--- ${f#$ROOT/}"
    grep -E '^\.field |const-string |^\.method ' "$f" 2>/dev/null | head -n 240
  done
  echo

  echo "[BASEURL_BUILDERS_AND_HOST_ASSIGNMENTS]"
  grep -RInE --include='*.smali' 'baseUrl|base_url|BASE_URL|setBaseUrl|changeBaseUrl|host|domain|URLInfo|DomainInfo|DCS|retrofit'     "$ROOT" 2>/dev/null     | grep -Ei '/com/(request|dcs|vod|interactive|core)/'     | head -n 2200 || true
} > "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-network-wiring.txt" || true
fi

echo "XUPER_NETWORK_WIRING_READY"
