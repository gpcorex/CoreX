#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/interface_synthesizer_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/interface-synthesizer-v1-$STAMP
mkdir -p "$ROOT" "$BACKUP"

echo "=== 1. INSTALL INTERFACE SYNTHESIZER V1 ==="
cat >"$ROOT/synthesize_interface.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, re
from collections import defaultdict
from pathlib import Path

PROJECTS=Path("/home/ubuntu/Central/projects")

RULES=[
 {
  "name":"loadRepository",
  "requires_any":["getrepositorydao","repomanager;->getrepository","repository;->getrepoid"],
  "evidence_terms":["getrepositorydao","getrepository","getrepoid"],
  "inputs":[{"name":"repoId","type":"long","required":True}],
  "outputs":[{"name":"repository","type":"Repository"}],
  "description":"Carga una entidad de repositorio a partir de su identificador."
 },
 {
  "name":"getRepositoryMirrors",
  "requires_any":["repository;->getmirrors","mirror;->geturl"],
  "evidence_terms":["getmirrors","mirror;->geturl"],
  "inputs":[{"name":"repoId","type":"long","required":True}],
  "outputs":[{"name":"mirrors","type":"List<URL>"}],
  "description":"Obtiene los mirrors observados para un repositorio."
 },
 {
  "name":"getRepositoryAddress",
  "requires_any":["repository;->getaddress"],
  "evidence_terms":["getaddress"],
  "inputs":[{"name":"repoId","type":"long","required":True}],
  "outputs":[{"name":"address","type":"String"}],
  "description":"Obtiene la dirección base observada del repositorio."
 },
 {
  "name":"getRepositoryCredentials",
  "requires_any":["repository;->getusername","repository;->getpassword","repository;->getcertificate"],
  "evidence_terms":["getusername","getpassword","getcertificate"],
  "inputs":[{"name":"repoId","type":"long","required":True}],
  "outputs":[
    {"name":"username","type":"String?"},
    {"name":"password","type":"String?"},
    {"name":"certificate","type":"String?"}
  ],
  "description":"Agrupa credenciales y certificado asociados al repositorio cuando existen."
 },
 {
  "name":"getRepositoryForVersion",
  "requires_any":["appversion;->getrepoid","repomanager;->getrepository"],
  "evidence_terms":["appversion;->getrepoid","getrepository"],
  "inputs":[{"name":"version","type":"AppVersion","required":True}],
  "outputs":[{"name":"repository","type":"Repository"}],
  "description":"Resuelve el repositorio asociado a una versión observada."
 },
 {
  "name":"getAppVersionFile",
  "requires_any":["appversion;->getfile"],
  "evidence_terms":["appversion;->getfile"],
  "inputs":[{"name":"version","type":"AppVersion","required":True}],
  "outputs":[{"name":"file","type":"FileV1"}],
  "description":"Obtiene el descriptor de archivo asociado a una versión."
 }
]

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("project_id")
    ap.add_argument("role")
    ap.add_argument("--slice",default="detail_metadata")
    args=ap.parse_args()

    root=PROJECTS/args.project_id
    slice_path=root/"work"/"component-packages"/args.role/"SLICES"/args.slice/"slice.json"
    if not slice_path.is_file():
        raise SystemExit("SLICE_NOT_FOUND")

    sl=json.load(open(slice_path,encoding="utf-8"))
    calls=sl.get("external_domain_calls") or []
    observed=[c.get("target","") for c in calls]
    observed_low=[x.lower() for x in observed]
    occurrence={c.get("target",""):c.get("occurrences",0) for c in calls}

    operations=[]
    for rule in RULES:
        if not any(any(term in x for x in observed_low) for term in rule["requires_any"]):
            continue
        evidence=[]
        for target in observed:
            low=target.lower()
            if any(term in low for term in rule["evidence_terms"]):
                evidence.append({
                    "target":target,
                    "occurrences":occurrence.get(target,0)
                })
        if not evidence:
            continue

        # Confidence derives from distinct supporting calls, not keyword score.
        distinct=len(evidence)
        total=sum(e["occurrences"] for e in evidence)
        if distinct>=2 and total>=4:
            confidence="high"
        elif total>=2:
            confidence="medium"
        else:
            confidence="low"

        operations.append({
          "name":rule["name"],
          "description":rule["description"],
          "inputs":rule["inputs"],
          "outputs":rule["outputs"],
          "confidence":confidence,
          "evidence":evidence
        })

    interface={
      "schema_version":"central.clean-interface.v1",
      "project_id":args.project_id,
      "component_role":args.role,
      "slice":args.slice,
      "status":"SYNTHESIZED",
      "operations":operations,
      "summary":{
        "operation_count":len(operations),
        "high_confidence_count":sum(1 for x in operations if x["confidence"]=="high"),
        "medium_confidence_count":sum(1 for x in operations if x["confidence"]=="medium"),
        "low_confidence_count":sum(1 for x in operations if x["confidence"]=="low")
      },
      "notes":[
        "Las operaciones se sintetizan únicamente desde llamadas de dominio observadas en el behavior slice.",
        "Los nombres son una interfaz limpia propuesta; no necesariamente coinciden con nombres originales.",
        "La confianza depende de evidencia múltiple y frecuencia observada, no de una sola coincidencia textual."
      ]
    }

    out=root/"work"/"component-packages"/args.role/"INTERFACE"
    out.mkdir(parents=True,exist_ok=True)
    (out/"interface.json").write_text(json.dumps(interface,ensure_ascii=False,indent=2)+chr(10),encoding="utf-8")

    lines=[
      f"# Clean Interface — {args.role}",
      "",
      f"Slice: {args.slice}",
      f"Operations: {len(operations)}",
      ""
    ]
    for op in operations:
        ins=", ".join(f"{x['name']}: {x['type']}" for x in op["inputs"])
        outs=", ".join(f"{x['name']}: {x['type']}" for x in op["outputs"])
        lines += [
          f"## {op['name']}({ins})",
          f"Returns: {outs}",
          f"Confidence: {op['confidence']}",
          op["description"],
          "Evidence:"
        ]
        for ev in op["evidence"]:
            lines.append(f"- {ev['target']} ({ev['occurrences']})")
        lines.append("")

    (out/"README.md").write_text("\n".join(lines)+chr(10),encoding="utf-8")

    print(json.dumps({
      "ok":True,
      "interface_path":str(out/"interface.json"),
      "readme_path":str(out/"README.md"),
      "interface":interface
    },ensure_ascii=False))

if __name__=="__main__":
    main()
PY

chmod 755 "$ROOT/synthesize_interface.py"
python3 -m py_compile "$ROOT/synthesize_interface.py"
echo INTERFACE_SYNTHESIZER_V1_SOURCE_OK

echo "=== 2. SYNTHESIZE DETAIL CLEAN INTERFACE ==="
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

OUT=$(sudo -u ubuntu python3 "$ROOT/synthesize_interface.py" "$LATEST" detail --slice detail_metadata)
echo "$OUT"

python3 - "$OUT" <<'PY'
import json,sys,os
x=json.loads(sys.argv[1])
assert x["ok"] is True
i=x["interface"]
assert i["status"]=="SYNTHESIZED"
assert i["summary"]["operation_count"]>=1
assert os.path.isfile(x["interface_path"])
assert os.path.isfile(x["readme_path"])
print("DETAIL_INTERFACE_SYNTHESIZER_REAL_PROJECT_OK")
print("summary="+json.dumps(i["summary"],ensure_ascii=False))
for op in i["operations"]:
    print("OPERATION "+op["name"]+" confidence="+op["confidence"]+" evidence="+str(len(op["evidence"])))
PY

echo CENTRAL_INTERFACE_SYNTHESIZER_V1_READY
echo "project_tested=$LATEST"
echo "backup=$BACKUP"
