#!/usr/bin/env bash
set -euo pipefail

BUILDER=/home/ubuntu/Central/component_package_builder_v1/build_component_package.py
CONTRACT=/home/ubuntu/Central/contract_extractor_v1/extract_component_contract.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/detail-component-validation-v1-$STAMP
mkdir -p "$BACKUP"

echo "=== 1. FIND LATEST REAL COMPLETED PROJECT ==="
LATEST=$(python3 - <<'PY'
import json
rows=json.load(open("/home/ubuntu/Central/auditor_ui_v1/data/runs.json",encoding="utf-8"))
for r in rows:
    if r.get("status")=="COMPLETED" and r.get("project_id"):
        print(r["project_id"])
        break
PY
)
test -n "$LATEST"
echo "project=$LATEST"

echo "=== 2. VALIDATE DETAIL COMPONENT PLAN ==="
PKG="/home/ubuntu/Central/projects/$LATEST/work/dependencies/detail/package.json"
test -f "$PKG"
python3 - "$PKG" <<'PY'
import json,sys
p=sys.argv[1]
x=json.load(open(p,encoding="utf-8"))
assert x.get("role")=="detail"
assert x.get("owned_core_verified") is True
core=[r for r in x.get("classification",[]) if r.get("kind")=="CORE"]
assert len(core)>=1
print("DETAIL_COMPONENT_PLAN_VERIFIED_OK")
print("core_classes="+str(len(core)))
for r in core:
    print("CORE "+r.get("class",""))
PY

echo "=== 3. BUILD DETAIL BUNDLE ==="
sudo -u ubuntu python3 "$BUILDER" "$LATEST" detail >/tmp/detail-bundle-$STAMP.json
cat /tmp/detail-bundle-$STAMP.json
python3 - "/tmp/detail-bundle-$STAMP.json" <<'PY'
import json,sys,os
x=json.load(open(sys.argv[1]))
m=x["manifest"]
assert m["owned_core_verified"] is True
assert m["buildable"] is True
assert m["status"]=="READY"
assert m["counts"]["core"]>=1
assert m["counts"]["missing_classes"]==0
assert os.path.isfile(os.path.join(x["bundle_path"],"manifest.json"))
assert os.path.isfile(os.path.join(x["bundle_path"],"README.md"))
print("DETAIL_COMPONENT_BUNDLE_OK")
print("bundle="+x["bundle_path"])
print("counts="+json.dumps(m["counts"],ensure_ascii=False))
PY

echo "=== 4. EXTRACT DETAIL CONTRACT ==="
sudo -u ubuntu python3 "$CONTRACT" "$LATEST" detail >/tmp/detail-contract-$STAMP.json
cat /tmp/detail-contract-$STAMP.json
python3 - "/tmp/detail-contract-$STAMP.json" <<'PY'
import json,sys,os
x=json.load(open(sys.argv[1]))
assert x["ok"] is True
assert not x.get("skipped",False)
c=x["contract"]
assert c["core_class_count"]>=1
assert os.path.isfile(x["contract_path"])
print("DETAIL_COMPONENT_CONTRACT_OK")
print("summary="+json.dumps(c["summary"],ensure_ascii=False))
print("network="+json.dumps(c["network"],ensure_ascii=False))
supported=[p["permission"] for p in c.get("permissions",[]) if p.get("status")=="supported_by_core"]
print("supported_permissions="+json.dumps(supported,ensure_ascii=False))
print("inputs="+json.dumps(c.get("inputs",[])[:12],ensure_ascii=False))
print("outputs="+json.dumps(c.get("outputs",[])[:12],ensure_ascii=False))
PY

echo "=== 5. CREATE DETAIL COMPONENT REPORT ==="
REPORT="/home/ubuntu/Central/projects/$LATEST/work/component-packages/detail/VALIDATION.md"
python3 - "$PKG" "/tmp/detail-bundle-$STAMP.json" "/tmp/detail-contract-$STAMP.json" "$REPORT" <<'PY'
import json,sys
pkg=json.load(open(sys.argv[1],encoding="utf-8"))
bundle=json.load(open(sys.argv[2],encoding="utf-8"))
contract=json.load(open(sys.argv[3],encoding="utf-8"))["contract"]
report=sys.argv[4]
m=bundle["manifest"]
supported=[p["permission"] for p in contract.get("permissions",[]) if p.get("status")=="supported_by_core"]
lines=[
"# Validación del componente Detalle",
"",
f"Proyecto: {pkg.get('project_id')}",
f"Componente: {pkg.get('name')}",
f"CORE verificado: {pkg.get('owned_core_verified')}",
f"Clases CORE: {m['counts']['core']}",
f"Dependencias compartidas: {m['counts']['shared']}",
f"Dependencias externas: {m['counts']['external']}",
f"Framework: {m['counts']['framework']}",
f"Recursos: {m['counts']['resources']}",
f"APIs: {m['counts']['apis']}",
"",
"## Contrato observado",
f"Tipos de entrada: {contract['summary']['observed_input_type_count']}",
f"Tipos de salida: {contract['summary']['observed_output_type_count']}",
f"Llamadas externas: {contract['summary']['external_call_count']}",
f"Indicadores de red: {contract['network']['uses_network_indicators']}",
f"Permisos con evidencia en CORE: {', '.join(supported) if supported else 'ninguno'}",
"",
"## Estado",
"VALIDATED_COMPONENT",
"",
"Este resultado valida extracción y contrato técnico. No declara todavía portabilidad ejecutable ni equivalencia funcional fuera de la app original."
]
open(report,"w",encoding="utf-8").write("\n".join(lines)+"\n")
print(report)
PY

test -s "$REPORT"
echo DETAIL_COMPONENT_REPORT_OK
echo CENTRAL_DETAIL_COMPONENT_VALIDATION_V1_READY
echo "report=$REPORT"
echo "project_tested=$LATEST"
echo "backup=$BACKUP"
