#!/usr/bin/env bash
set -euo pipefail

REPO="/opt/corex/repo"
APK="/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef/source/AU-20260923-104449-e62e2c-XuperTv-N0F4C3-v6.73.0.apk"
OUT="/var/lib/conector/xuper-actions-stage2.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p /var/lib/conector
: > "$OUT"

{
  echo "XUPER_ACTIONS_STAGE2"
  echo "timestamp=$(date -Is)"
  echo "apk=$APK"
  test -f "$APK"
  ls -lh "$APK"
  sha256sum "$APK"
  echo
  echo "=== ABI ==="
  python3 - "$APK" <<'PY'
import sys, zipfile
apk=sys.argv[1]
with zipfile.ZipFile(apk) as z:
    abis=sorted({n.split('/')[1] for n in z.namelist() if n.startswith('lib/') and n.count('/')>=2})
print("abis=" + (",".join(abis) if abis else "none"))
PY
  echo
  echo "=== REMOTE ==="
  git -C "$REPO" remote -v
} >> "$OUT"

git clone --no-checkout "$REPO" "$TMP/repo" >/dev/null 2>&1
cd "$TMP/repo"
git config user.email "central@local"
git config user.name "Central"
git checkout --orphan xuper-runtime-input >/dev/null 2>&1
git rm -rf . >/dev/null 2>&1 || true
mkdir -p runtime-input
cp "$APK" runtime-input/XuperTv-N0F4C3-v6.73.0.apk
git add runtime-input/XuperTv-N0F4C3-v6.73.0.apk
git commit -m "Stage temporary Xuper runtime input" >/dev/null
git push -f origin xuper-runtime-input

{
  echo
  echo "=== PUSHED ==="
  git rev-parse HEAD
  echo "branch=xuper-runtime-input"
  echo "note=workflow must be dispatched from GitHub after branch push"
} >> "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-actions-stage2.txt" || true
fi

echo "XUPER_ACTIONS_STAGE2_READY"
cat "$OUT"
