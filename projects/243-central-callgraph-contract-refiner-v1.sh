#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/callgraph_refiner_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/callgraph-refiner-v1-$STAMP
mkdir -p "$ROOT" "$BACKUP"

echo "=== 1. INSTALL CALL GRAPH + CONTRACT REFINER V1 ==="
cat >"$ROOT/refine_component_contract.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, re
from collections import Counter, defaultdict, deque
from pathlib import Path

PROJECTS=Path("/home/ubuntu/Central/projects")

METHOD_START_RE=re.compile(r'^\.method\s+(.+?)\s+([A-Za-z0-9_$<>-]+)\((.*?)\)(\S+)\s*$',re.M)
INVOKE_RE=re.compile(r'invoke-[^\s]+\s+\{[^}]*\},\s+(L[^;]+;)->([^\(]+)\(([^)]*)\)(\S+)')
CONST_STR_RE=re.compile(r'const-string(?:/jumbo)?\s+v\d+,\s+"(.*?)"')
PERMISSION_PATTERNS={
 "android.permission.INTERNET":["okhttp","retrofit","http://","https://","urlconnection","socket","uri"],
 "android.permission.BLUETOOTH":["bluetooth"],
 "android.permission.BLUETOOTH_CONNECT":["bluetooth"],
 "android.permission.BLUETOOTH_SCAN":["bluetooth","scan"],
 "android.permission.CAMERA":["camera","camerax"],
 "android.permission.NFC":["nfc"],
 "android.permission.READ_EXTERNAL_STORAGE":["fileinputstream","externalstorage","environment"],
 "android.permission.WRITE_EXTERNAL_STORAGE":["fileoutputstream","externalstorage","environment"],
 "android.permission.WAKE_LOCK":["wakelock","powermanager"],
}
FRAMEWORK_PREFIXES=("Ljava/","Ljavax/","Landroid/","Landroidx/","Lkotlin/","Lkotlinx/","Ldalvik/","Lorg/json/","Lorg/xml/","Lorg/w3c/")

def dotted(d):
    return d[1:-1].replace("/",".") if d.startswith("L") and d.endswith(";") else d

def method_key(owner,name,params,ret):
    return f"{owner}->{name}({params}){ret}"

def owner_from_smali(txt):
    m=re.search(r'^\.class\s+.*?\s+(L[^;]+;)',txt,re.M)
    return m.group(1) if m else None

def method_blocks(txt):
    starts=list(METHOD_START_RE.finditer(txt))
    out=[]
    for i,m in enumerate(starts):
        end=txt.find("\n.end method",m.end())
        if end<0:
            end=starts[i+1].start() if i+1<len(starts) else len(txt)
        else:
            end=end+len("\n.end method")
        out.append((m,txt[m.start():end]))
    return out

def is_framework(owner):
    return owner.startswith(FRAMEWORK_PREFIXES)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("project_id")
    ap.add_argument("role")
    ap.add_argument("--max-depth",type=int,default=4)
    args=ap.parse_args()

    root=PROJECTS/args.project_id
    bundle=root/"work"/"component-packages"/args.role
    manifest_path=bundle/"manifest.json"
    contract_path=bundle/"CONTRACT"/"contract.json"
    dep_path=root/"work"/"dependencies"/args.role/"package.json"
    decoded=root/"work"/"android-audit"/"decoded"

    for p in (manifest_path,contract_path,dep_path):
        if not p.is_file():
            raise SystemExit(f"MISSING_REQUIRED_FILE:{p}")
    if not decoded.is_dir():
        raise SystemExit("DECODED_TREE_NOT_FOUND")

    manifest=json.load(open(manifest_path,encoding="utf-8"))
    contract=json.load(open(contract_path,encoding="utf-8"))
    dep=json.load(open(dep_path,encoding="utf-8"))

    if not manifest.get("owned_core_verified"):
        result={"ok":True,"skipped":True,"reason":"NO_OWNED_CORE","project_id":args.project_id,"role":args.role}
        print(json.dumps(result,ensure_ascii=False))
        return

    # Build descriptor -> source map once.
    desc_to_path={}
    for p in decoded.rglob("*.smali"):
        try:txt=p.read_text(encoding="utf-8",errors="ignore")
        except Exception:continue
        owner=owner_from_smali(txt)
        if owner:desc_to_path[owner]=p

    core_desc={row["descriptor"] for row in dep.get("classification",[]) if row.get("kind")=="CORE"}
    shared_desc={row["descriptor"] for row in dep.get("classification",[]) if row.get("kind") in {"DIRECT","TRANSITIVE","SHARED"}}
    external_desc={row["descriptor"] for row in dep.get("classification",[]) if row.get("kind")=="EXTERNAL"}
    framework_desc={row["descriptor"] for row in dep.get("classification",[]) if row.get("kind")=="FRAMEWORK"}

    methods={}
    edges=[]
    permission_evidence=defaultdict(list)
    network_hosts=set()

    owners_to_scan=core_desc | shared_desc
    for owner in sorted(owners_to_scan):
        p=desc_to_path.get(owner)
        if not p:continue
        txt=p.read_text(encoding="utf-8",errors="ignore")
        for m,block in method_blocks(txt):
            mods,name,params,ret=m.groups()
            key=method_key(owner,name,params,ret)
            visibility="private"
            if " public " in f" {mods} " or mods.startswith("public "):visibility="public"
            elif " protected " in f" {mods} " or mods.startswith("protected "):visibility="protected"
            elif " private " in f" {mods} " or mods.startswith("private "):visibility="private"
            else:visibility="package"

            calls=[]
            for inv in INVOKE_RE.finditer(block):
                tgt_owner,tgt_name,tgt_params,tgt_ret=inv.groups()
                tgt=method_key(tgt_owner,tgt_name,tgt_params,tgt_ret)
                if tgt_owner in core_desc:kind="CORE"
                elif tgt_owner in shared_desc:kind="SHARED"
                elif tgt_owner in external_desc:kind="EXTERNAL"
                elif tgt_owner in framework_desc or is_framework(tgt_owner):kind="FRAMEWORK"
                elif tgt_owner in desc_to_path:kind="APP_OTHER"
                else:kind="UNKNOWN"
                calls.append({"target":tgt,"owner":dotted(tgt_owner),"name":tgt_name,"kind":kind})
                edges.append({"from":key,"to":tgt,"kind":kind})

            low=block.lower()
            per_method=[]
            for perm,hints in PERMISSION_PATTERNS.items():
                hit=next((h for h in hints if h in low),None)
                if hit:
                    ev={"method":key,"file":str(p.relative_to(decoded)),"hint":hit}
                    permission_evidence[perm].append(ev)
                    per_method.append({"permission":perm,"hint":hit})

            strings=CONST_STR_RE.findall(block)
            hosts=[]
            for s in strings:
                for u in re.findall(r'https?://[^\s"\']+',s):
                    host=u.split("/")[2] if "/" in u[8:] else u
                    network_hosts.add(host);hosts.append(host)

            methods[key]={
                "owner":dotted(owner),
                "name":name,
                "descriptor":key,
                "visibility":visibility,
                "is_static":" static " in f" {mods} ",
                "call_count":len(calls),
                "calls":calls,
                "permission_hints":per_method,
                "hosts":sorted(set(hosts)),
                "file":str(p.relative_to(decoded))
            }

    entrypoints=[k for k,v in methods.items() if v["owner"] in {dotted(x) for x in core_desc} and v["visibility"] in {"public","protected"} and v["name"] not in {"<init>","<clinit>"}]

    # Reachability from CORE public/protected methods.
    adj=defaultdict(list)
    for e in edges:adj[e["from"]].append(e)
    reached=set(entrypoints)
    q=deque((k,0) for k in entrypoints)
    while q:
        cur,depth=q.popleft()
        if depth>=args.max_depth:continue
        for e in adj.get(cur,[]):
            tgt=e["to"]
            if tgt in methods and tgt not in reached:
                reached.add(tgt);q.append((tgt,depth+1))

    essential_external=Counter()
    essential_framework=Counter()
    essential_app_other=Counter()
    essential_permissions=defaultdict(list)

    for k in reached:
        m=methods.get(k)
        if not m:continue
        for c in m["calls"]:
            if c["kind"]=="EXTERNAL":essential_external[c["owner"]+"->"+c["name"]]+=1
            elif c["kind"]=="FRAMEWORK":essential_framework[c["owner"]+"->"+c["name"]]+=1
            elif c["kind"]=="APP_OTHER":essential_app_other[c["owner"]+"->"+c["name"]]+=1
        for pe in m["permission_hints"]:
            essential_permissions[pe["permission"]].append({"method":k,"hint":pe["hint"]})

    # Conservative clean-interface candidates: observed public/protected CORE methods only.
    clean_candidates=[]
    for k in entrypoints:
        m=methods[k]
        lname=m["name"].lower()
        if any(tok in lname for tok in ("get","load","open","show","detail","app","repo","version","install","update","fetch","find","select","bind")):
            clean_candidates.append({
                "observed_method":k,
                "candidate_name":m["name"],
                "owner":m["owner"],
                "reason":"public_or_protected_core_method_with_domain_signal"
            })

    refined_permissions=[]
    declared=set(manifest.get("permissions") or [])
    for perm in sorted(declared):
        ev=essential_permissions.get(perm,[])
        refined_permissions.append({
            "permission":perm,
            "status":"observed_on_reachable_path" if ev else "not_observed_on_reachable_path",
            "evidence":ev[:20]
        })

    out=bundle/"REFINED"
    out.mkdir(parents=True,exist_ok=True)

    graph={
      "schema_version":"central.component-callgraph.v1",
      "project_id":args.project_id,
      "role":args.role,
      "entrypoints":entrypoints,
      "methods":methods,
      "edges":edges,
      "reachable_method_count":len(reached),
      "total_method_count":len(methods),
      "max_depth":args.max_depth
    }
    (out/"callgraph.json").write_text(json.dumps(graph,ensure_ascii=False,indent=2)+chr(10),encoding="utf-8")

    refined={
      "schema_version":"central.component-contract.refined.v1",
      "project_id":args.project_id,
      "component_id":manifest.get("component_id"),
      "name":manifest.get("name"),
      "role":args.role,
      "status":"REFINED",
      "entrypoint_count":len(entrypoints),
      "reachable_method_count":len(reached),
      "external_calls_reachable":[{"target":k,"occurrences":v} for k,v in essential_external.most_common(100)],
      "framework_calls_reachable":[{"target":k,"occurrences":v} for k,v in essential_framework.most_common(100)],
      "app_other_calls_reachable":[{"target":k,"occurrences":v} for k,v in essential_app_other.most_common(100)],
      "permissions":refined_permissions,
      "network":{"hosts_observed_on_reachable_paths":sorted(network_hosts)},
      "clean_interface_candidates":clean_candidates[:50],
      "summary":{
        "entrypoint_count":len(entrypoints),
        "reachable_method_count":len(reached),
        "reachable_external_call_count":sum(essential_external.values()),
        "reachable_framework_call_count":sum(essential_framework.values()),
        "reachable_app_other_call_count":sum(essential_app_other.values()),
        "reachable_permission_count":sum(1 for x in refined_permissions if x["status"]=="observed_on_reachable_path")
      },
      "notes":[
        "V1 refina el contrato usando alcanzabilidad desde métodos públicos/protegidos del CORE.",
        "Los candidatos de interfaz limpia son observaciones, no una API final.",
        "Los permisos se marcan solo cuando aparecen en rutas alcanzables según este análisis estático."
      ]
    }
    (out/"refined-contract.json").write_text(json.dumps(refined,ensure_ascii=False,indent=2)+chr(10),encoding="utf-8")

    manifest["refined_contract_path"]=str(out/"refined-contract.json")
    manifest["callgraph_path"]=str(out/"callgraph.json")
    manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+chr(10),encoding="utf-8")

    print(json.dumps({"ok":True,"project_id":args.project_id,"role":args.role,"refined_contract_path":str(out/"refined-contract.json"),"callgraph_path":str(out/"callgraph.json"),"refined":refined},ensure_ascii=False))

if __name__=="__main__":
    main()
PY

chmod 755 "$ROOT/refine_component_contract.py"
python3 -m py_compile "$ROOT/refine_component_contract.py"
echo CALLGRAPH_REFINER_V1_SOURCE_OK

echo "=== 2. RUN ON LATEST DETAIL COMPONENT ==="
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

OUT=$(sudo -u ubuntu python3 "$ROOT/refine_component_contract.py" "$LATEST" detail)
echo "$OUT"
python3 - "$OUT" <<'PY'
import json,sys,os
x=json.loads(sys.argv[1])
assert x["ok"] is True
r=x["refined"]
assert r["status"]=="REFINED"
assert r["entrypoint_count"]>=1
assert os.path.isfile(x["refined_contract_path"])
assert os.path.isfile(x["callgraph_path"])
print("DETAIL_CALLGRAPH_REFINER_REAL_PROJECT_OK")
print("summary="+json.dumps(r["summary"],ensure_ascii=False))
print("clean_interface_candidates="+json.dumps(r["clean_interface_candidates"][:12],ensure_ascii=False))
print("reachable_permissions="+json.dumps([p["permission"] for p in r["permissions"] if p["status"]=="observed_on_reachable_path"],ensure_ascii=False))
print("reachable_external_calls="+json.dumps(r["external_calls_reachable"][:12],ensure_ascii=False))
PY

echo "=== 3. WRITE HUMAN REPORT ==="
REPORT="/home/ubuntu/Central/projects/$LATEST/work/component-packages/detail/REFINED/REPORT.md"
python3 - "$OUT" "$REPORT" <<'PY'
import json,sys
x=json.loads(sys.argv[1])["refined"]
path=sys.argv[2]
perms=[p["permission"] for p in x["permissions"] if p["status"]=="observed_on_reachable_path"]
lines=[
"# Detail — Call Graph + Contract Refinement",
"",
f"Entrypoints observados: {x['summary']['entrypoint_count']}",
f"Métodos alcanzables: {x['summary']['reachable_method_count']}",
f"Llamadas externas alcanzables: {x['summary']['reachable_external_call_count']}",
f"Llamadas framework alcanzables: {x['summary']['reachable_framework_call_count']}",
f"Llamadas a otras clases de la app: {x['summary']['reachable_app_other_call_count']}",
f"Permisos observados en rutas alcanzables: {', '.join(perms) if perms else 'ninguno'}",
"",
"## Candidatos de interfaz limpia"
]
for c in x["clean_interface_candidates"][:20]:
    lines.append(f"- {c['candidate_name']}  ←  {c['observed_method']}")
lines += ["","## Estado","REFINED_COMPONENT_CONTRACT","","Los candidatos anteriores derivan de métodos observados y no constituyen todavía una API final."]
open(path,"w",encoding="utf-8").write("\n".join(lines)+"\n")
print(path)
PY
test -s "$REPORT"
echo DETAIL_CALLGRAPH_REFINER_REPORT_OK

echo CENTRAL_CALLGRAPH_REFINER_V1_READY
echo "project_tested=$LATEST"
echo "report=$REPORT"
echo "backup=$BACKUP"
