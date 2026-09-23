#!/usr/bin/env bash
set -euo pipefail

RES=/home/ubuntu/Central/dependency_resolver_v1/resolve_android_dependencies.py
BUILDER=/home/ubuntu/Central/component_package_builder_v1/build_component_package.py
CONTRACT=/home/ubuntu/Central/contract_extractor_v1/extract_component_contract.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/component-verification-v5-$STAMP
mkdir -p "$BACKUP"
cp -a "$RES" "$BACKUP/resolve_android_dependencies.py.before"
cp -a "$BUILDER" "$BACKUP/build_component_package.py.before"
cp -a "$CONTRACT" "$BACKUP/extract_component_contract.py.before"

echo "=== 1. PATCH RESOLVER: ZERO OWNED CORE = UNCONFIRMED ==="
python3 - "$RES" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

old='''        package={
          "schema_version":"central.component-package.v3",
'''
new='''        verified_owned_core=bool(seeds)
        effective_confidence=csum.get("confidence") if verified_owned_core else "low"
        effective_reuse=csum.get("reuse_assessment") if verified_owned_core else "unknown"

        package={
          "schema_version":"central.component-package.v3",
'''
if old not in s:
    raise SystemExit("PACKAGE_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

s=s.replace(
'''          "confidence":csum.get("confidence"),
          "reuse_assessment":csum.get("reuse_assessment"),
''',
'''          "confidence":effective_confidence,
          "reuse_assessment":effective_reuse,
          "owned_core_verified":verified_owned_core,
''',1)

s=s.replace(
'''          "confidence":csum.get("confidence"),"reuse_assessment":csum.get("reuse_assessment"),
          "seed_count":len(seeds),"raw_closure_count":len(closure),
''',
'''          "confidence":effective_confidence,"reuse_assessment":effective_reuse,
          "owned_core_verified":verified_owned_core,
          "seed_count":len(seeds),"raw_closure_count":len(closure),
''',1)

p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$RES"
echo COMPONENT_VERIFICATION_V5_RESOLVER_SOURCE_OK

echo "=== 2. PATCH BUILDER: EMPTY CORE IS A VALID NON-BUILDABLE RESULT ==="
python3 - "$BUILDER" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

old='''    class_rows=pkg.get("classification") or []
    copied={"CORE":0,"DIRECT":0,"TRANSITIVE":0,"SHARED":0,"EXTERNAL":0,"FRAMEWORK":0}
'''
new='''    class_rows=pkg.get("classification") or []
    owned_core_verified=bool(pkg.get("owned_core_verified", any(r.get("kind")=="CORE" for r in class_rows)))
    copied={"CORE":0,"DIRECT":0,"TRANSITIVE":0,"SHARED":0,"EXTERNAL":0,"FRAMEWORK":0}
'''
if old not in s: raise SystemExit("BUILDER_CORE_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

old2='''      "source_copy_included":True,
      "counts":{
'''
new2='''      "source_copy_included":True,
      "owned_core_verified":owned_core_verified,
      "buildable":owned_core_verified,
      "status":"READY" if owned_core_verified else "UNCONFIRMED_COMPONENT",
      "counts":{
'''
if old2 not in s: raise SystemExit("BUILDER_MANIFEST_ANCHOR_NOT_FOUND")
s=s.replace(old2,new2,1)

old3='''      "notes":[
        "Este bundle es evidencia técnica extraída, no una app ejecutable.",
'''
new3='''      "notes":[
        "Si owned_core_verified=false, el componente fue sugerido por evidencia genérica pero no se encontró núcleo propio de la aplicación.",
        "Este bundle es evidencia técnica extraída, no una app ejecutable.",
'''
if old3 not in s: raise SystemExit("BUILDER_NOTES_ANCHOR_NOT_FOUND")
s=s.replace(old3,new3,1)

p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$BUILDER"
echo COMPONENT_VERIFICATION_V5_BUILDER_SOURCE_OK

echo "=== 3. PATCH CONTRACT: EMPTY CORE RETURNS SKIPPED, NOT ERROR ==="
python3 - "$CONTRACT" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

old='''    core_files=list((bundle/"CORE").rglob("*.smali"))
    if not core_files:raise SystemExit("CORE_EMPTY")

    methods=[]
'''
new='''    core_files=list((bundle/"CORE").rglob("*.smali"))
    if not core_files:
        contract={
          "schema_version":"central.component-contract.v1",
          "project_id":args.project_id,
          "component_id":manifest.get("component_id"),
          "name":manifest.get("name"),
          "role":args.role,
          "status":"SKIPPED_NO_OWNED_CORE",
          "core_class_count":0,
          "inputs":[],
          "outputs":[],
          "public_method_observations":[],
          "external_calls":[],
          "network":{"declared_api_bases":[],"hosts_observed_in_core":[],"uses_network_indicators":False},
          "permissions":[],
          "summary":{"declared_permission_count":len(manifest.get("permissions") or []),"supported_permission_count":0,"observed_input_type_count":0,"observed_output_type_count":0,"external_call_count":0},
          "notes":["No se encontró código CORE perteneciente a la aplicación para este componente; no se infiere contrato."]
        }
        out=bundle/"CONTRACT";out.mkdir(parents=True,exist_ok=True)
        cp=out/"contract.json"
        cp.write_text(json.dumps(contract,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
        print(json.dumps({"ok":True,"skipped":True,"reason":"NO_OWNED_CORE","project_id":args.project_id,"role":args.role,"contract_path":str(cp),"contract":contract},ensure_ascii=False))
        return

    methods=[]
'''
if old not in s: raise SystemExit("CONTRACT_EMPTY_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$CONTRACT"
echo COMPONENT_VERIFICATION_V5_CONTRACT_SOURCE_OK

echo "=== 4. RERUN LATEST REAL PROJECT ==="
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

TMP=/tmp/component-verification-v5-$STAMP.log
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

echo "=== 5. REBUILD + CONTRACT STREAM COMPONENT ==="
sudo -u ubuntu python3 "$BUILDER" "$LATEST" stream_resolution >/tmp/component-v5-bundle.json
cat /tmp/component-v5-bundle.json
python3 - <<'PY'
import json
x=json.load(open("/tmp/component-v5-bundle.json"))
m=x["manifest"]
assert m["owned_core_verified"] is False
assert m["buildable"] is False
assert m["status"]=="UNCONFIRMED_COMPONENT"
print("COMPONENT_VERIFICATION_V5_BUNDLE_STATUS_OK")
PY

sudo -u ubuntu python3 "$CONTRACT" "$LATEST" stream_resolution >/tmp/component-v5-contract.json
cat /tmp/component-v5-contract.json
python3 - <<'PY'
import json
x=json.load(open("/tmp/component-v5-contract.json"))
assert x["ok"] is True
assert x.get("skipped") is True
assert x["contract"]["status"]=="SKIPPED_NO_OWNED_CORE"
print("COMPONENT_VERIFICATION_V5_CONTRACT_SKIP_OK")
PY

echo CENTRAL_COMPONENT_VERIFICATION_V5_READY
echo "project_tested=$LATEST"
echo "backup=$BACKUP"
