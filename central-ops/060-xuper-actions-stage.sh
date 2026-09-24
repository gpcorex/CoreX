#!/usr/bin/env bash
set -euo pipefail

APK="/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef/source/AU-20260923-104449-e62e2c-XuperTv-N0F4C3-v6.73.0.apk"
OUT="/var/lib/conector/xuper-actions-stage.txt"
mkdir -p /var/lib/conector
: > "$OUT"

{
  echo "XUPER_ACTIONS_STAGE"
  echo "timestamp=$(date -Is)"
  echo "apk=$APK"
  test -f "$APK"
  ls -lh "$APK"
  sha256sum "$APK"
  echo
  echo "=== ZIP ABI DIRS ==="
  python3 - "$APK" <<'PY'
import sys, zipfile
apk=sys.argv[1]
with zipfile.ZipFile(apk) as z:
    abis=sorted({n.split('/')[1] for n in z.namelist() if n.startswith('lib/') and n.count('/')>=2})
    print("abis=" + (",".join(abis) if abis else "none"))
PY
  echo
  echo "=== GH AUTH ==="
  gh auth status 2>&1 || true
} >> "$OUT"

ASSET="/tmp/XuperTv-N0F4C3-v6.73.0.apk"
cp "$APK" "$ASSET"

if gh release view xuper-runtime-input --repo gpcorex/CoreX >/dev/null 2>&1; then
  gh release upload xuper-runtime-input "$ASSET" --repo gpcorex/CoreX --clobber
else
  gh release create xuper-runtime-input "$ASSET"     --repo gpcorex/CoreX     --title "Xuper runtime input"     --notes "Temporary private runtime-test input."
fi

gh workflow run xuper-runtime-proof.yml --repo gpcorex/CoreX --ref main

{
  echo
  echo "=== WORKFLOW TRIGGERED ==="
  gh run list --repo gpcorex/CoreX --workflow xuper-runtime-proof.yml --limit 3
} >> "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-actions-stage.txt" || true
fi

echo "XUPER_ACTIONS_STAGE_READY"
cat "$OUT"
