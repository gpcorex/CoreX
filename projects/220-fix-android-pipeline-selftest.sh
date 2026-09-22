#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/pipeline_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/android-pipeline-v1-test-fix-$STAMP
mkdir -p "$BACKUP"
cp -a "$ROOT/run_android_pipeline.py" "$BACKUP/run_android_pipeline.py"

echo "=== 1. VERIFY PIPELINE SOURCE ==="
test -x "$ROOT/run_android_pipeline.py"
python3 -m py_compile "$ROOT/run_android_pipeline.py"
echo ANDROID_PIPELINE_V1_SOURCE_RECHECK_OK

echo "=== 2. VERIFY CURRENT FIXTURE ==="
test -s /tmp/central-auditor-v1.apk
echo ANDROID_PIPELINE_V1_FIXTURE_PRESENT_OK

echo "=== 3. RUN PIPELINE SELFTEST CLEANLY ==="
OUT=$(sudo -u ubuntu python3 "$ROOT/run_android_pipeline.py" /tmp/central-auditor-v1.apk --kind apk --name "Pipeline Fixture")
printf '%s\n' "$OUT"

TMPJSON=$(mktemp)
printf '%s\n' "$OUT" > "$TMPJSON"
python3 - "$TMPJSON" <<'PY'
import json,sys
p=sys.argv[1]
with open(p,encoding="utf-8") as f:
    x=json.load(f)
assert x["ok"] is True,x
assert x["audit"]["dex_count"]>=1,x
assert x["audit"]["native_libs"]>=1,x
assert x["deobfuscation_status"] in {"SKIPPED_NO_DECODED_TREE","OK"},x
print("ANDROID_PIPELINE_V1_FALLBACK_RETEST_OK")
PY
rm -f "$TMPJSON"

echo "=== 4. VERIFY COMPONENTS ==="
test -x /home/ubuntu/Central/ingest_v1/ingest.py
test -x /home/ubuntu/Central/auditor_v1/audit_android.py
test -x /home/ubuntu/Central/deobfuscator_v1/deobfuscate_android.py
echo ANDROID_PIPELINE_V1_COMPONENTS_RETEST_OK

echo CENTRAL_ANDROID_PIPELINE_V1_TEST_FIXED_READY
echo "backup=$BACKUP"
