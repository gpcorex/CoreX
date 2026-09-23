#!/usr/bin/env bash
set -euo pipefail

CONTRACT=/home/ubuntu/Central/contract_extractor_v1/extract_component_contract.py
RES=/home/ubuntu/Central/dependency_resolver_v1/resolve_android_dependencies.py
BUILDER=/home/ubuntu/Central/component_package_builder_v1/build_component_package.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/component-verification-v5-fix-$STAMP
mkdir -p "$BACKUP"
cp -a "$CONTRACT" "$BACKUP/extract_component_contract.py.before"

echo "=== 1. REPAIR CONTRACT EXTRACTOR NEWLINE SYNTAX ==="
python3 - "$CONTRACT" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

pat=r'cp\.write_text\(json\.dumps\(contract,ensure_ascii=False,indent=2\)\+.*?encoding="utf-8"\)'
rep='cp.write_text(json.dumps(contract,ensure_ascii=False,indent=2)+chr(10),encoding="utf-8")'
s2,n=re.subn(pat,rep,s,count=1,flags=re.S)
if n!=1:
    raise SystemExit(f"CONTRACT_NEWLINE_REPAIR_ANCHOR_NOT_FOUND count={n}")
p.write_text(s2,encoding="utf-8")
PY

python3 -m py_compile "$CONTRACT"
echo CONTRACT_EXTRACTOR_V5_SYNTAX_REPAIRED_OK

echo "=== 2. RERUN LATEST REAL PROJECT RESOLVER ==="
LATEST=$(python3 - <<'PY'
import json
rows=json.load(open("/home/ubuntu/Central/auditor_ui_v1/data/runs.json",encoding="utf-8"))
for r in rows:
    if r.get("status")=="COMPLETED" and r.get("project_id"):
        print(r["project_id"]);break
PY
)
test -n "$LATEST"
echo "project=$LATEST"

TMP=/tmp/component-verification-v5-fix-$STAMP.log
sudo -u ubuntu python3 "$RES" "$LATEST" 2>&1 | tee "$TMP"
LAST=$(tail -n1 "$TMP")
python3 - "$LAST" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x["ok"] is True
for c in x["components"]:
    state="VERIFIED" if c.get("owned_core_verified") else "UNCONFIRMED"
    print(f'{c["name"]}: {state} core={c["seed_count"]} confidence={c["confidence"]} reuse={c["reuse_assessment"]}')
stream=[c for c in x["components"] if c["role"]=="stream_resolution"][0]
assert stream["owned_core_verified"] is False
assert stream["seed_count"]==0
print("COMPONENT_VERIFICATION_V5_FALSE_POSITIVE_FIXED_OK")
PY

echo "=== 3. REBUILD STREAM BUNDLE ==="
sudo -u ubuntu python3 "$BUILDER" "$LATEST" stream_resolution >/tmp/component-v5-fix-bundle.json
cat /tmp/component-v5-fix-bundle.json
python3 - <<'PY'
import json
x=json.load(open("/tmp/component-v5-fix-bundle.json"))
m=x["manifest"]
assert m["owned_core_verified"] is False
assert m["buildable"] is False
assert m["status"]=="UNCONFIRMED_COMPONENT"
print("COMPONENT_VERIFICATION_V5_BUNDLE_STATUS_OK")
PY

echo "=== 4. REEXTRACT STREAM CONTRACT ==="
sudo -u ubuntu python3 "$CONTRACT" "$LATEST" stream_resolution >/tmp/component-v5-fix-contract.json
cat /tmp/component-v5-fix-contract.json
python3 - <<'PY'
import json
x=json.load(open("/tmp/component-v5-fix-contract.json"))
assert x["ok"] is True
assert x.get("skipped") is True
assert x["contract"]["status"]=="SKIPPED_NO_OWNED_CORE"
print("COMPONENT_VERIFICATION_V5_CONTRACT_SKIP_OK")
PY

echo CENTRAL_COMPONENT_VERIFICATION_V5_FIXED_READY
echo "project_tested=$LATEST"
echo "backup=$BACKUP"
