#!/usr/bin/env bash
set -euo pipefail

RES=/home/ubuntu/Central/dependency_resolver_v1/resolve_android_dependencies.py
STAMP=$(date +%Y%m%d-%H%M%S)
TMP=/tmp/dependency-resolver-v3-$STAMP.log

echo "=== 1. STOP SILENT V2 TEST IF STILL RUNNING ==="
PIDS=$(pgrep -f "python3 $RES" || true)
if [ -n "$PIDS" ]; then
  echo "stopping_pids=$PIDS"
  kill $PIDS 2>/dev/null || true
  sleep 1
fi
echo DEPENDENCY_RESOLVER_V2_SILENT_RUN_STOPPED_OK

echo "=== 2. FIND LATEST REAL COMPLETED PROJECT ==="
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

echo "=== 3. RUN V2 WITH LIVE PROGRESS ==="
START=$(date +%s)
set +e
set -o pipefail
sudo -u ubuntu python3 "$RES" "$LATEST" 2>&1 | tee "$TMP"
RC=$?
set -e
END=$(date +%s)
ELAPSED=$((END-START))
echo "elapsed_sec=$ELAPSED"
test "$RC" -eq 0

LAST=$(tail -n1 "$TMP")
python3 - "$LAST" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x["ok"] is True
assert x["component_count"]>=1
print("DEPENDENCY_RESOLVER_V3_RESULT_OK")
for c in x["components"]:
    print(f'{c["name"]}: nucleo={c["seed_count"]} directas={c["direct_dependency_count"]} cierre={c["closure_count"]} recursos={c["resource_count"]} APIs={c["api_count"]}')
PY

echo DEPENDENCY_RESOLVER_V3_LIVE_PROGRESS_OK
echo CENTRAL_DEPENDENCY_RESOLVER_V3_READY
echo "log=$TMP"
