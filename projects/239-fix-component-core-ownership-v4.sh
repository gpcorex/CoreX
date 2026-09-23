#!/usr/bin/env bash
set -euo pipefail

RES=/home/ubuntu/Central/dependency_resolver_v1/resolve_android_dependencies.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/dependency-core-ownership-v4-$STAMP
mkdir -p "$BACKUP"
cp -a "$RES" "$BACKUP/resolve_android_dependencies.py.before"

echo "=== 1. PATCH CORE OWNERSHIP RULES ==="
python3 - "$RES" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

old='''        if len(seeds)<3:
            for _,d in keyword_scores.get(role,[])[:20]:
                seeds.add(d)
'''
new='''        if len(seeds)<3:
            # Semantic fallback must prefer classes owned by the application.
            # Library/framework classes may mention generic words such as uri,
            # stream, camera, media, etc. and must never become CORE merely
            # because of those incidental strings.
            candidates=keyword_scores.get(role,[])
            owned=[d for _,d in candidates if app_prefix and d.startswith(app_prefix)]
            if owned:
                for d in owned[:20]:
                    seeds.add(d)
            else:
                # If package ownership is unknown, exclude known framework namespaces.
                for _,d in candidates:
                    if is_framework(d):
                        continue
                    seeds.add(d)
                    if len(seeds)>=20:
                        break
'''
if old not in s:
    raise SystemExit("SEED_FALLBACK_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

# Exact matches may also have selected framework/library classes from evidence text.
old2='''        closure=set(seeds); direct=set(); q=deque((d,0) for d in seeds)
'''
new2='''        # CORE means application-owned code. Anything outside the app package
        # can still enter the dependency closure but not the seed set.
        if app_prefix:
            seeds={d for d in seeds if d.startswith(app_prefix)}
        else:
            seeds={d for d in seeds if not is_framework(d)}

        closure=set(seeds); direct=set(); q=deque((d,0) for d in seeds)
'''
if old2 not in s:
    raise SystemExit("CORE_OWNERSHIP_ANCHOR_NOT_FOUND")
s=s.replace(old2,new2,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$RES"
echo DEPENDENCY_CORE_OWNERSHIP_V4_SOURCE_OK

echo "=== 2. RERUN RESOLVER ON LATEST REAL PROJECT ==="
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
TMP=/tmp/dependency-core-v4-$STAMP.log
sudo -u ubuntu python3 "$RES" "$LATEST" 2>&1 | tee "$TMP"
LAST=$(tail -n1 "$TMP")
python3 - "$LAST" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x["ok"] is True
for c in x["components"]:
    print(f'{c["name"]}: nucleo={c["seed_count"]} minimo={c["minimal_internal_count"]} framework={c["framework_count"]} external={c["external_count"]}')
stream=[c for c in x["components"] if c["role"]=="stream_resolution"]
assert stream, "STREAM_COMPONENT_MISSING"
print("DEPENDENCY_CORE_OWNERSHIP_V4_RESOLVER_OK")
PY

echo "=== 3. REBUILD STREAM BUNDLE ==="
sudo -u ubuntu python3 /home/ubuntu/Central/component_package_builder_v1/build_component_package.py "$LATEST" stream_resolution >/tmp/core-v4-bundle.json
cat /tmp/core-v4-bundle.json
python3 - <<'PY'
import json, pathlib
x=json.load(open("/tmp/core-v4-bundle.json"))
root=pathlib.Path(x["bundle_path"])/"CORE"
bad=[]
for p in root.rglob("*.smali"):
    rel=str(p.relative_to(root))
    if rel.startswith(("smali/android/","smali/androidx/","smali/java/","smali/kotlin/")):
        bad.append(rel)
assert not bad, bad[:20]
print("COMPONENT_PACKAGE_CORE_OWNERSHIP_V4_OK")
PY

echo "=== 4. REEXTRACT STREAM CONTRACT ==="
sudo -u ubuntu python3 /home/ubuntu/Central/contract_extractor_v1/extract_component_contract.py "$LATEST" stream_resolution >/tmp/core-v4-contract.json
cat /tmp/core-v4-contract.json
python3 - <<'PY'
import json
x=json.load(open("/tmp/core-v4-contract.json"))
c=x["contract"]
print("summary="+json.dumps(c["summary"],ensure_ascii=False))
print("network="+json.dumps(c["network"],ensure_ascii=False))
print("supported_permissions="+json.dumps([p["permission"] for p in c["permissions"] if p["status"]=="supported_by_core"],ensure_ascii=False))
print("CONTRACT_CORE_OWNERSHIP_V4_OK")
PY

echo CENTRAL_DEPENDENCY_CORE_OWNERSHIP_V4_READY
echo "project_tested=$LATEST"
echo "backup=$BACKUP"
