#!/usr/bin/env bash
set -euo pipefail

RES=/home/ubuntu/Central/dependency_resolver_v1/resolve_android_dependencies.py
UI=/home/ubuntu/Central/auditor_ui_v1/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/dependency-pruning-v3-$STAMP
mkdir -p "$BACKUP"
cp -a "$RES" "$BACKUP/resolve_android_dependencies.py.before"
cp -a "$UI" "$BACKUP/server.py.before"

echo "=== 1. INSTALL DEPENDENCY RESOLVER V3 WITH PRUNING ==="
cat >"$RES" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, re
from collections import Counter, defaultdict, deque
from pathlib import Path

PROJECTS=Path("/home/ubuntu/Central/projects")

ROLE_WORDS={
 "catalog":["catalog","browse","feed","repo","repository"],
 "search":["search","query","filter"],
 "detail":["detail","details"],
 "player":["player","playback","exo","media"],
 "stream_resolution":["m3u8","mpd","dash","hls","stream","playlist","manifest"],
 "subtitles":["subtitle","caption","vtt","srt"],
 "authentication":["login","signin","auth","oauth","token","session","jwt"],
 "favorites":["favorite","bookmark","watchlist"],
 "downloads":["download","offline"],
 "profiles":["profile","account"],
 "ads":["admob","advert","doubleclick","interstitial"],
 "analytics":["analytics","telemetry","crashlytics","sentry"],
 "settings":["settings","preferences"],
 "navigation":["navigation","navcontroller","deeplink"],
 "data_source":["api","endpoint","retrofit","okhttp","graphql","repository","datasource","http"],
}

FRAMEWORK_PREFIXES=(
 "Landroid/","Landroidx/","Ljava/","Ljavax/","Lkotlin/","Lkotlinx/",
 "Ldalvik/","Lorg/xml/","Lorg/json/","Lorg/w3c/","Lorg/xmlpull/"
)

CLASS_RE=re.compile(r'^\.class\s+.*?\s+(L[^;]+;)',re.M)
REF_RE=re.compile(r'L[0-9A-Za-z_$/.\-]+;')
RES_RE=re.compile(r'(?i)\b(?:R\$[A-Za-z0-9_]+|0x7f[0-9a-f]{6})\b')

def emit(event,**kw):
    x={"event":event};x.update(kw);print(json.dumps(x,ensure_ascii=False),flush=True)

def dotted(d):
    return d[1:-1].replace("/",".") if d.startswith("L") and d.endswith(";") else d

def recursive_package_name(x):
    if isinstance(x,dict):
        for k,v in x.items():
            if k=="package_name" and isinstance(v,str) and v.strip():
                return v.strip()
        for v in x.values():
            r=recursive_package_name(v)
            if r:return r
    elif isinstance(x,list):
        for v in x:
            r=recursive_package_name(v)
            if r:return r
    return None

def is_framework(d):
    return d.startswith(FRAMEWORK_PREFIXES)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("project_id")
    ap.add_argument("--depth",type=int,default=2)
    ap.add_argument("--max-classes",type=int,default=350)
    args=ap.parse_args()

    root=PROJECTS/args.project_id
    analysis_path=root/"canon"/"analysis.json"
    comp_path=root/"work"/"functional"/"components.json"
    decoded=root/"work"/"android-audit"/"decoded"
    if not analysis_path.is_file():raise SystemExit("ANALYSIS_NOT_FOUND")
    if not comp_path.is_file():raise SystemExit("COMPONENTS_NOT_FOUND")
    if not decoded.is_dir():raise SystemExit("DECODED_TREE_NOT_FOUND")

    analysis=json.load(open(analysis_path,encoding="utf-8"))
    comp_summary=json.load(open(comp_path,encoding="utf-8"))
    components=comp_summary.get("components") or []
    evidence={e.get("id"):e for e in analysis.get("evidence",[]) if isinstance(e,dict)}
    canon_components={c.get("id"):c for c in analysis.get("components",[]) if isinstance(c,dict)}
    package_name=recursive_package_name(analysis) or ""
    app_prefix=("L"+package_name.replace(".","/")+"/") if package_name else ""

    emit("resolver_progress",phase="index_smali",current=0,total=None,detail="Indexando clases")
    class_map={}; text_map={}; refs_map={}; resource_ref_map={}
    keyword_scores={role:[] for role in ROLE_WORDS}
    smali_files=list(decoded.rglob("*.smali"))
    total=len(smali_files)
    for i,p in enumerate(smali_files,1):
        try:txt=p.read_text(encoding="utf-8",errors="ignore")
        except Exception:continue
        m=CLASS_RE.search(txt)
        if not m:continue
        d=m.group(1); low=txt.lower()
        class_map[d]=p; text_map[d]=txt
        refs_map[d]={r for r in REF_RE.findall(txt) if r!=d}
        resource_ref_map[d]=set(RES_RE.findall(txt))
        for role,kws in ROLE_WORDS.items():
            score=sum(low.count(k) for k in kws)
            if score:keyword_scores[role].append((score,d))
        if i==1 or i%1000==0 or i==total:
            emit("resolver_progress",phase="index_smali",current=i,total=total,detail=f"classes={len(class_map)}")

    for role in keyword_scores:
        keyword_scores[role].sort(key=lambda x:(-x[0],x[1]))

    emit("resolver_progress",phase="index_resources",current=0,total=None,detail="Indexando recursos")
    resource_index=defaultdict(list)
    res_files=[p for p in decoded.rglob("*") if p.is_file() and "/res/" in str(p)]
    for i,p in enumerate(res_files,1):
        resource_index[p.stem.lower()].append(str(p.relative_to(decoded)))
        if i==1 or i%1000==0 or i==len(res_files):
            emit("resolver_progress",phase="index_resources",current=i,total=len(res_files),detail=None)

    # First pass: raw closures for every component.
    raw={}
    for ci,csum in enumerate(components,1):
        cid=csum["id"]; role=csum["role"]
        emit("resolver_progress",phase="raw_component",current=ci,total=len(components),detail=csum.get("name"))
        canon=canon_components.get(cid) or {}
        texts=list(set(canon.get("members") or []))
        for eid in canon.get("evidence_refs") or []:
            ev=evidence.get(eid)
            if ev:texts += [str(ev.get("locator") or ""),str(ev.get("excerpt") or "")]

        seeds=set()
        for d,p in class_map.items():
            rel=str(p.relative_to(decoded)); dot=dotted(d)
            if any(t and (rel in t or dot in t or d in t) for t in texts):
                seeds.add(d)
        if len(seeds)<3:
            for _,d in keyword_scores.get(role,[])[:20]:
                seeds.add(d)

        closure=set(seeds); direct=set(); q=deque((d,0) for d in seeds)
        while q and len(closure)<args.max_classes:
            d,depth=q.popleft()
            refs={r for r in refs_map.get(d,set()) if r in class_map}
            if depth==0:direct.update(refs)
            if depth>=args.depth:continue
            for r in refs:
                if r not in closure:
                    closure.add(r);q.append((r,depth+1))
                    if len(closure)>=args.max_classes:break
        raw[cid]={"seeds":seeds,"direct":direct,"closure":closure,"role":role,"name":csum.get("name"),"summary":csum}

    presence=Counter()
    for item in raw.values():
        for d in item["closure"]:presence[d]+=1

    out_root=root/"work"/"dependencies";out_root.mkdir(parents=True,exist_ok=True)
    resolved=[]
    for ci,(cid,item) in enumerate(raw.items(),1):
        emit("resolver_progress",phase="prune_component",current=ci,total=len(raw),detail=item["name"])
        seeds=item["seeds"]; direct=item["direct"]; closure=item["closure"]; csum=item["summary"]; role=item["role"]

        classes=[]
        counts=Counter()
        minimal_internal=[]
        declared_shared=[]; declared_external=[]; declared_framework=[]
        for d in sorted(closure):
            if d in seeds:kind="CORE"
            elif is_framework(d):kind="FRAMEWORK"
            elif app_prefix and not d.startswith(app_prefix):kind="EXTERNAL"
            elif presence[d]>=2:kind="SHARED"
            elif d in direct:kind="DIRECT"
            else:kind="TRANSITIVE"
            counts[kind]+=1
            classes.append({"class":dotted(d),"descriptor":d,"kind":kind,"shared_by_components":presence[d]})
            if kind in {"CORE","DIRECT","TRANSITIVE"}:minimal_internal.append(d)
            elif kind=="SHARED":declared_shared.append(d)
            elif kind=="EXTERNAL":declared_external.append(d)
            elif kind=="FRAMEWORK":declared_framework.append(d)

        # Resources only from minimal internal classes to avoid common-resource inflation.
        resource_refs=set()
        for d in minimal_internal:resource_refs.update(resource_ref_map.get(d,set()))
        resources=set()
        for rr in resource_refs:
            if rr.lower().startswith("0x7f"):continue
            stem=rr.split("$")[-1].lower()
            resources.update(resource_index.get(stem,[]))

        apis=[];kws=ROLE_WORDS.get(role,[])
        for api in (analysis.get("data") or {}).get("apis",[]):
            txt=json.dumps(api,ensure_ascii=False).lower()
            if any(k in txt for k in kws):apis.append(api.get("base"))

        pkgdir=out_root/re.sub(r"[^A-Za-z0-9._-]+","_",role);pkgdir.mkdir(parents=True,exist_ok=True)
        package={
          "schema_version":"central.component-package.v3",
          "project_id":args.project_id,
          "component_id":cid,
          "name":item["name"],
          "role":role,
          "confidence":csum.get("confidence"),
          "reuse_assessment":csum.get("reuse_assessment"),
          "app_package":package_name or None,
          "classification":classes,
          "minimal_internal_classes":sorted(dotted(d) for d in minimal_internal),
          "shared_dependencies":sorted(dotted(d) for d in declared_shared),
          "external_dependencies":sorted(dotted(d) for d in declared_external),
          "framework_dependencies":sorted(dotted(d) for d in declared_framework),
          "resources":sorted(resources),
          "resource_refs":sorted(resource_refs),
          "permissions":list((analysis.get("security") or {}).get("permissions") or []),
          "external_api_bases":sorted(x for x in set(apis) if x),
          "limits":{"depth":args.depth,"max_classes":args.max_classes,"raw_closure_truncated":len(closure)>=args.max_classes},
          "export_strategy":"reconstruct_clean" if csum.get("reuse_assessment")=="rebuild_recommended" else "adapt_or_reconstruct",
          "source_copy_included":False
        }
        (pkgdir/"package.json").write_text(json.dumps(package,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

        resolved.append({
          "id":cid,"name":item["name"],"role":role,
          "confidence":csum.get("confidence"),"reuse_assessment":csum.get("reuse_assessment"),
          "seed_count":len(seeds),"raw_closure_count":len(closure),
          "minimal_internal_count":len(minimal_internal),
          "direct_count":counts["DIRECT"],"transitive_count":counts["TRANSITIVE"],
          "shared_count":counts["SHARED"],"framework_count":counts["FRAMEWORK"],"external_count":counts["EXTERNAL"],
          "resource_count":len(resources),"api_count":len(package["external_api_bases"]),
          "raw_closure_truncated":package["limits"]["raw_closure_truncated"],
          "package_path":str(pkgdir/"package.json")
        })

    result={
      "ok":True,"project_id":args.project_id,"component_count":len(resolved),
      "app_package":package_name or None,"components":resolved
    }
    (out_root/"summary.json").write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    emit("resolver_progress",phase="done",current=len(resolved),total=len(resolved),detail="Poda terminada")
    print(json.dumps(result,ensure_ascii=False))

if __name__=="__main__":
    main()
PY
chmod 755 "$RES"
python3 -m py_compile "$RES"
echo DEPENDENCY_PRUNING_V3_SOURCE_OK

echo "=== 2. UPDATE AUDITOR UI SUMMARY ==="
python3 - "$UI" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")
old="""     l.innerHTML='<div><strong>'+c.name+'</strong></div><small>núcleo '+c.seed_count+' · directas '+c.direct_dependency_count+' · cierre '+c.closure_count+' clases · recursos '+c.resource_count+' · APIs '+c.api_count+trunc+'</small>'
"""
new="""     const minimal=(c.minimal_internal_count!==undefined?c.minimal_internal_count:c.closure_count)
     const shared=(c.shared_count!==undefined?' · compartidas '+c.shared_count:'')
     const fw=(c.framework_count!==undefined?' · framework '+c.framework_count:'')
     const ext=(c.external_count!==undefined?' · externas '+c.external_count:'')
     l.innerHTML='<div><strong>'+c.name+'</strong></div><small>núcleo '+c.seed_count+' · mínimo interno '+minimal+shared+fw+ext+' · recursos '+c.resource_count+' · APIs '+c.api_count+trunc+'</small>'
"""
if old not in s:
    raise SystemExit("UI_DEPENDENCY_SUMMARY_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)
s=s.replace("const trunc=c.closure_truncated?' · límite alcanzado':''","const trunc=(c.raw_closure_truncated||c.closure_truncated)?' · cierre bruto limitado':''",1)
p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$UI"
echo DEPENDENCY_PRUNING_V3_UI_SOURCE_OK

echo "=== 3. TEST LATEST REAL PROJECT WITH LIVE PROGRESS ==="
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
TMP=/tmp/dependency-pruning-v3-$STAMP.log
START=$(date +%s)
set +e
set -o pipefail
sudo -u ubuntu python3 "$RES" "$LATEST" 2>&1 | tee "$TMP"
RC=$?
set -e
END=$(date +%s)
echo "elapsed_sec=$((END-START))"
test "$RC" -eq 0

LAST=$(tail -n1 "$TMP")
python3 - "$LAST" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x["ok"] is True and x["component_count"]>=1
print("DEPENDENCY_PRUNING_V3_REAL_PROJECT_OK")
for c in x["components"]:
    print(f'{c["name"]}: nucleo={c["seed_count"]} bruto={c["raw_closure_count"]} minimo={c["minimal_internal_count"]} shared={c["shared_count"]} framework={c["framework_count"]} external={c["external_count"]} recursos={c["resource_count"]} APIs={c["api_count"]}')
PY

echo "=== 4. RESTART UI + PUBLIC CHECK ==="
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8792/api/health >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo DEPENDENCY_PRUNING_V3_PUBLIC_UI_OK

echo CENTRAL_DEPENDENCY_PRUNING_V3_READY
echo "backup=$BACKUP"
