#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/behavior_slicer_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/behavior-slicer-v1-$STAMP
mkdir -p "$ROOT" "$BACKUP"

echo "=== 1. INSTALL BEHAVIOR SLICER V1 ==="
cat >"$ROOT/slice_component_behavior.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, re
from collections import defaultdict, deque, Counter
from pathlib import Path

PROJECTS=Path("/home/ubuntu/Central/projects")

KEEP_HINTS={
 "detail_metadata":[
   "getmetadata","getrepository","getrepoid","geturl","getversions","getversion",
   "appversion","mirror","repository","metadata","repo","version"
 ]
}
DROP_HINTS=[
 "materialalertdialogbuilder","dialoginterface","glide","qrcode","qr","uninstall",
 "installapk","showqrcode","imageview","snackbar","toast","intent","activityresult",
 "permissions","bluetooth","camera","nfc"
]

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("project_id")
    ap.add_argument("role")
    ap.add_argument("--slice",default="detail_metadata")
    ap.add_argument("--depth",type=int,default=3)
    args=ap.parse_args()

    root=PROJECTS/args.project_id
    refined=root/"work"/"component-packages"/args.role/"REFINED"
    cg_path=refined/"callgraph.json"
    rc_path=refined/"refined-contract.json"
    if not cg_path.is_file(): raise SystemExit("CALLGRAPH_NOT_FOUND")
    if not rc_path.is_file(): raise SystemExit("REFINED_CONTRACT_NOT_FOUND")

    cg=json.load(open(cg_path,encoding="utf-8"))
    rc=json.load(open(rc_path,encoding="utf-8"))

    methods=cg.get("methods") or {}
    edges=cg.get("edges") or []
    adj=defaultdict(list)
    rev=defaultdict(list)
    for e in edges:
        adj[e["from"]].append(e)
        rev[e["to"]].append(e)

    hints=KEEP_HINTS.get(args.slice,[])
    seeds=set()
    excluded=set()

    for k,m in methods.items():
        low=(k+" "+m.get("name","")+" "+m.get("owner","")).lower()
        if any(d in low for d in DROP_HINTS):
            excluded.add(k)
            continue
        if any(h in low for h in hints):
            seeds.add(k)

    # also seed from known useful external calls in refined contract
    for row in rc.get("external_calls_reachable") or []:
        tgt=row.get("target","")
        low=tgt.lower()
        if any(h in low for h in hints) and not any(d in low for d in DROP_HINTS):
            for e in rev.get(tgt,[]):
                seeds.add(e["from"])

    # Slice only through non-UI/non-side-effect nodes
    kept=set(seeds)
    q=deque((s,0) for s in seeds)
    while q:
        cur,depth=q.popleft()
        if depth>=args.depth: continue
        for e in adj.get(cur,[]):
            tgt=e["to"]
            low=tgt.lower()
            if any(d in low for d in DROP_HINTS):
                continue
            # Keep internal reachable method nodes and essential external domain calls.
            if tgt in methods:
                if tgt not in kept:
                    kept.add(tgt); q.append((tgt,depth+1))
            else:
                if any(h in low for h in hints):
                    kept.add(tgt)

    kept_edges=[e for e in edges if e["from"] in kept and e["to"] in kept]

    external=Counter()
    framework=Counter()
    app_other=Counter()
    for e in kept_edges:
        kind=e.get("kind")
        tgt=e.get("to")
        if kind=="EXTERNAL": external[tgt]+=1
        elif kind=="FRAMEWORK": framework[tgt]+=1
        elif kind=="APP_OTHER": app_other[tgt]+=1

    clean_api=[]
    seen=set()
    for tgt,count in external.most_common():
        low=tgt.lower()
        candidate=None
        if "getmetadata" in low: candidate="getAppMetadata"
        elif "getrepository" in low or "getrepoid" in low: candidate="getRepository"
        elif "mirror" in low or "geturl" in low: candidate="getMirrors"
        elif "version" in low: candidate="getVersions"
        if candidate and candidate not in seen:
            clean_api.append({"name":candidate,"derived_from":tgt,"occurrences":count})
            seen.add(candidate)

    out=root/"work"/"component-packages"/args.role/"SLICES"/args.slice
    out.mkdir(parents=True,exist_ok=True)
    result={
      "schema_version":"central.behavior-slice.v1",
      "project_id":args.project_id,
      "component_role":args.role,
      "slice":args.slice,
      "seed_method_count":len(seeds),
      "kept_node_count":len(kept),
      "kept_edge_count":len(kept_edges),
      "excluded_method_count":len(excluded),
      "kept_methods":[k for k in kept if k in methods],
      "external_domain_calls":[{"target":k,"occurrences":v} for k,v in external.most_common(100)],
      "framework_calls":[{"target":k,"occurrences":v} for k,v in framework.most_common(100)],
      "app_other_calls":[{"target":k,"occurrences":v} for k,v in app_other.most_common(100)],
      "clean_interface_candidates":clean_api,
      "notes":[
        "V1 poda rutas laterales por heurística semántica.",
        "Excluye UI/diálogos/imágenes/QR/instalación cuando aparecen en el camino.",
        "Los candidatos de interfaz limpia derivan de llamadas de dominio observadas."
      ]
    }
    (out/"slice.json").write_text(json.dumps(result,ensure_ascii=False,indent=2)+chr(10),encoding="utf-8")

    lines=[
      f"# Behavior Slice: {args.slice}",
      "",
      f"Seed methods: {len(seeds)}",
      f"Kept nodes: {len(kept)}",
      f"Kept edges: {len(kept_edges)}",
      "",
      "## Clean interface candidates"
    ]
    for x in clean_api:
        lines.append(f"- {x['name']} ← {x['derived_from']}")
    lines += ["","## External domain calls"]
    for x in result["external_domain_calls"][:30]:
        lines.append(f"- {x['target']} ({x['occurrences']})")
    (out/"REPORT.md").write_text("\n".join(lines)+chr(10),encoding="utf-8")

    print(json.dumps({"ok":True,"slice_path":str(out/"slice.json"),"report_path":str(out/"REPORT.md"),"result":result},ensure_ascii=False))

if __name__=="__main__":
    main()
PY

chmod 755 "$ROOT/slice_component_behavior.py"
python3 -m py_compile "$ROOT/slice_component_behavior.py"
echo BEHAVIOR_SLICER_V1_SOURCE_OK

echo "=== 2. RUN DETAIL METADATA SLICE ON LATEST PROJECT ==="
LATEST=$(python3 - <<'PY'
import json
rows=json.load(open("/home/ubuntu/Central/auditor_ui_v1/data/runs.json",encoding="utf-8"))
for r in rows:
    if r.get("status")=="COMPLETED" and r.get("project_id"):
        print(r["project_id"]); break
PY
)
test -n "$LATEST"
echo "project=$LATEST"

OUT=$(sudo -u ubuntu python3 "$ROOT/slice_component_behavior.py" "$LATEST" detail --slice detail_metadata)
echo "$OUT"

python3 - "$OUT" <<'PY'
import json,sys,os
x=json.loads(sys.argv[1])
assert x["ok"] is True
r=x["result"]
assert r["seed_method_count"]>=1
assert r["kept_node_count"]>=1
assert os.path.isfile(x["slice_path"])
assert os.path.isfile(x["report_path"])
print("DETAIL_BEHAVIOR_SLICE_REAL_PROJECT_OK")
print("summary="+json.dumps({
 "seed_method_count":r["seed_method_count"],
 "kept_node_count":r["kept_node_count"],
 "kept_edge_count":r["kept_edge_count"],
 "excluded_method_count":r["excluded_method_count"]
},ensure_ascii=False))
print("clean_interface_candidates="+json.dumps(r["clean_interface_candidates"],ensure_ascii=False))
print("external_domain_calls="+json.dumps(r["external_domain_calls"][:12],ensure_ascii=False))
PY

echo CENTRAL_BEHAVIOR_SLICER_V1_READY
echo "project_tested=$LATEST"
echo "backup=$BACKUP"
