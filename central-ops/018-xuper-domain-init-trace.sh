#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/xuper-domain-init-trace.txt"
mkdir -p /var/lib/conector

ROOT="/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef/work/android-audit/decoded"
WELCOME="$ROOT/smali/com/interactive/brasiliptv/ui/activity/WelcomeActivity.smali"

{
  echo "XUPER_DOMAIN_INIT_TRACE_V1"
  echo "generated_at=$(date -Is)"
  echo

  echo "[WELCOME_INIT_DOMAIN_CONTEXT]"
  if [ -f "$WELCOME" ]; then
    sed -n '1380,1785p' "$WELCOME"
    echo
    sed -n '2120,2245p' "$WELCOME"
  fi

  echo
  echo "[CLASS_V2_A]"
  for f in "$ROOT"/smali*/v2/a.smali; do
    [ -f "$f" ] || continue
    echo "--- ${f#$ROOT/}"
    sed -n '1,1200p' "$f"
  done

  echo
  echo "[CLASS_Z0_H]"
  for f in "$ROOT"/smali*/z0/h.smali; do
    [ -f "$f" ] || continue
    echo "--- ${f#$ROOT/}"
    sed -n '1,1800p' "$f"
  done

  echo
  echo "[DCS_BUSINESS_AND_RESULTS]"
  for f in     "$ROOT/smali/com/dcs/bean/Business.smali"     "$ROOT/smali/com/dcs/bean/V1Data.smali"     "$ROOT/smali/com/dcs/bean/V1Bean.smali"     "$ROOT/smali/com/dcs/bean/N1Data.smali"     "$ROOT/smali/com/dcs/bean/LogResult.smali"
  do
    [ -f "$f" ] || continue
    echo "--- ${f#$ROOT/}"
    grep -E '^\.field |const-string |^\.method ' "$f" | head -n 500
  done

  echo
  echo "[DOMAIN_SECURITY_STRINGS]"
  grep -RInE --include='*.xml' --include='*.smali' 'domain_is_security|Init domain|host_alias|DomainInfo|URLInfo|first|second'     "$ROOT/res" "$ROOT/smali" "$ROOT/smali_classes2" "$ROOT/smali_classes3" 2>/dev/null     | head -n 1800 || true
} > "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-domain-init-trace.txt" || true
fi

echo "XUPER_DOMAIN_INIT_TRACE_READY"
