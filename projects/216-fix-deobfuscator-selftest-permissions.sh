#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/deobfuscator_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/deobfuscator-v1-selftest-perms-$STAMP
mkdir -p "$BACKUP"
cp -a "$ROOT/deobfuscate_android.py" "$BACKUP/deobfuscate_android.py"

echo "=== 1. FIX SELFTEST PROJECT OWNERSHIP ==="
TMPROOT=/home/ubuntu/Central/projects/deobfuscator-v1-selftest
sudo chown -R ubuntu:ubuntu "$TMPROOT"
sudo find "$TMPROOT" -type d -exec chmod 755 {} +
sudo find "$TMPROOT" -type f -exec chmod 644 {} +
test -w "$TMPROOT/work"
echo DEOBFUSCATOR_SELFTEST_PROJECT_WRITABLE_OK

echo "=== 2. RETEST DEOBFUSCATOR ==="
OUT=$(sudo -u ubuntu python3 "$ROOT/deobfuscate_android.py" deobfuscator-v1-selftest)
echo "$OUT"

python3 - <<'PY'
import json
from pathlib import Path
w=Path("/home/ubuntu/Central/projects/deobfuscator-v1-selftest/work/deobfuscation")
dec=json.load(open(w/"decoded-strings.json",encoding="utf-8"))
routines=json.load(open(w/"decoder-routines.json",encoding="utf-8"))
assert any(x["decoded"]=="https://api.example.test/catalog" for x in dec),dec
assert any(x["method"]=="base64" for x in dec),dec
assert len(routines)>=1,routines
assert any("xor-int" in h for r in routines for h in r["hints"]),routines
print("DEOBFUSCATOR_V1_BATCH_DECODE_RETEST_OK")
print("DEOBFUSCATOR_V1_ROUTINE_DETECTION_RETEST_OK")
PY

python3 /home/ubuntu/Central/canon/v1/validate_canon.py "$TMPROOT/canon/analysis.json"
echo DEOBFUSCATOR_V1_CANON_RETEST_OK
echo CENTRAL_DEOBFUSCATOR_V1_PERMISSIONS_FIXED_READY
echo "backup=$BACKUP"
