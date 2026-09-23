#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/dependency_resolver_v1
RES="$ROOT/resolve_android_dependencies.py"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/dependency-resolver-v2-$STAMP
mkdir -p "$BACKUP"
cp -a "$RES" "$BACKUP/resolve_android_dependencies.py.before"

echo "=== 1. INSTALL OPTIMIZED DEPENDENCY RESOLVER V2 ==="
cat >"$RES" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, hashlib, json, re, time
from collections import defaultdict, deque
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

CLASS_RE=re.compile(r'^\.class\s+.*?\s+(L[^;]+;)',re.M)
REF_RE=re.compile(r'L[0-9A-Za-z_$/.\-]+;')
RES_RE=re.compile(r'(?i)\b(?:R\$[A-Za-z0-9_]+|0x7f[0-9a-f]{6})\b')

def emit(event,**kw):
    obj={"event":event}; obj.update(kw)
    print(json.dumps(obj,ensure_ascii=False),flush=True)

def descriptor_to_dotted(d):
    return d[1:-1].replace("/",".") if d.startswith("L") and d.endswith(";") else d

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

    if not analysis_path.is_file(): raise SystemExit("ANALYSIS_NOT_FOUND")
    if not comp_path.is_file(): raise SystemExit("COMPONENTS_NOT_FOUND")
    if not decoded.is_dir(): raise SystemExit("DECODED_TREE_NOT_FOUND")

    analysis=json.load(open(analysis_path,encoding="utf-8"))
    comp_summary=json.load(open(comp_path,encoding="utf-8"))
    components=comp_summary.get("components") or []
    evidence={e.get("id"):e for e in analysis.get("evidence",[]) if isinstance(e,dict)}
    canon_components={c.get("id"):c for c in analysis.get("components",[]) if isinstance(c,dict)}

    emit("resolver_progress",phase="index_smali",current=0,total=None,detail="Indexando clases una sola vez")

    class_map={}
    file_to_class={}
    text_map={}
    refs_map={}
    resource_ref_map={}
    keyword_scores={role:[] for role in ROLE_WORDS}

    smali_files=list(decoded.rglob("*.smali"))
    total=len(smali_files)
    for i,p in enumerate(smali_files,1):
        try: txt=p.read_text(encoding="utf-8",errors="ignore")
        except Exception: continue
        m=CLASS_RE.search(txt)
        if not m: continue
        d=m.group(1)
        low=txt.lower()
        class_map[d]=p
        file_to_class[p]=d
        text_map[d]=txt
        refs_map[d]={r for r in REF_RE.findall(txt) if r!=d}
        resource_ref_map[d]=set(RES_RE.findall(txt))
        for role,kws in ROLE_WORDS.items():
            score=sum(low.count(k) for k in kws)
            if score:
                keyword_scores[role].append((score,d))
        if i==1 or i%1000==0 or i==total:
            emit("resolver_progress",phase="index_smali",current=i,total=total,detail=f"classes={len(class_map)}")

    for role in keyword_scores:
        keyword_scores[role].sort(key=lambda x:(-x[0],x[1]))

    emit("resolver_progress",phase="index_resources",current=0,total=None,detail="Indexando recursos una sola vez")
    resource_index=defaultdict(list)
    res_files=[p for p in decoded.rglob("*") if p.is_file() and "/res/" in str(p)]
    for i,p in enumerate(res_files,1):
        resource_index[p.stem.lower()].append(str(p.relative_to(decoded)))
        if i==1 or i%1000==0 or i==len(res_files):
            emit("resolver_progress",phase="index_resources",current=i,total=len(res_files),detail=None)

    out_root=root/"work"/"dependencies"
    out_root.mkdir(parents=True,exist_ok=True)

    resolved=[]
    total_components=len(components)
    for ci,csum in enumerate(components,1):
        cid=csum["id"]
        role=csum["role"]
        emit("resolver_progress",phase="component",current=ci,total=total_components,detail=csum.get("name"))

        canon=canon_components.get(cid) or {}
        members=set(canon.get("members") or [])
        evrefs=canon.get("evidence_refs") or []
        member_texts=list(members)
        for eid in evrefs:
            ev=evidence.get(eid)
            if ev:
                member_texts += [str(ev.get("locator") or ""),str(ev.get("excerpt") or "")]

        seed_classes=set()
        # Match against descriptors/dotted names without rereading files.
        for d,p in class_map.items():
            dotted=descriptor_to_dotted(d)
            rel=str(p.relative_to(decoded))
            for text in member_texts:
                if text and (rel in text or dotted in text or d in text):
                    seed_classes.add(d); break

        # Semantic fallback from precomputed scores.
        if len(seed_classes)<3:
            for _,d in keyword_scores.get(role,[])[:20]:
                seed_classes.add(d)

        closure=set(seed_classes)
        direct=set()
        q=deque((d,0) for d in seed_classes)
        while q and len(closure)<args.max_classes:
            d,depth=q.popleft()
            refs={r for r in refs_map.get(d,set()) if r in class_map}
            if depth==0: direct.update(refs)
            if depth>=args.depth: continue
            for r in refs:
                if r not in closure:
                    closure.add(r)
                    q.append((r,depth+1))
                    if len(closure)>=args.max_classes: break

        resource_refs=set()
        for d in closure:
            resource_refs.update(resource_ref_map.get(d,set()))

        resources=set()
        for rr in resource_refs:
            if rr.lower().startswith("0x7f"): continue
            stem=rr.split("$")[-1].lower()
            resources.update(resource_index.get(stem,[]))

        perms=list((analysis.get("security") or {}).get("permissions") or [])
        apis=[]
        kws=ROLE_WORDS.get(role,[])
        for api in (analysis.get("data") or {}).get("apis",[]):
            txt=json.dumps(api,ensure_ascii=False).lower()
            if any(k in txt for k in kws):
                apis.append(api.get("base"))

        files=[class_map[d] for d in closure if d in class_map]
        package={
            "schema_version":"central.component-package.v2",
            "project_id":args.project_id,
            "component_id":cid,
            "name":csum.get("name"),
            "role":role,
            "confidence":csum.get("confidence"),
            "reuse_assessment":csum.get("reuse_assessment"),
            "seed_classes":sorted(descriptor_to_dotted(d) for d in seed_classes),
            "direct_dependencies":sorted(descriptor_to_dotted(d) for d in direct),
            "dependency_closure":sorted(descriptor_to_dotted(d) for d in closure),
            "smali_files":[str(p.relative_to(decoded)) for p in sorted(files)],
            "resources":sorted(resources),
            "resource_refs":sorted(resource_refs),
            "permissions":perms,
            "external_api_bases":sorted(x for x in set(apis) if x),
            "limits":{"depth":args.depth,"max_classes":args.max_classes,"closure_truncated":len(closure)>=args.max_classes},
            "export_strategy":"reconstruct_clean" if csum.get("reuse_assessment")=="rebuild_recommended" else "adapt_or_reconstruct",
            "source_copy_included":False
        }

        safe=re.sub(r"[^A-Za-z0-9._-]+","_",role)
        pkgdir=out_root/safe
        pkgdir.mkdir(parents=True,exist_ok=True)
        (pkgdir/"package.json").write_text(json.dumps(package,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

        resolved.append({
            "id":cid,"name":csum.get("name"),"role":role,
            "confidence":csum.get("confidence"),
            "reuse_assessment":csum.get("reuse_assessment"),
            "seed_count":len(seed_classes),
            "direct_dependency_count":len(direct),
            "closure_count":len(closure),
            "resource_count":len(resources),
            "api_count":len(package["external_api_bases"]),
            "closure_truncated":package["limits"]["closure_truncated"],
            "package_path":str(pkgdir/"package.json")
        })

    result={"ok":True,"project_id":args.project_id,"component_count":len(resolved),"components":resolved}
    (out_root/"summary.json").write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    emit("resolver_progress",phase="done",current=total_components,total=total_components,detail="Resolución terminada")
    print(json.dumps(result,ensure_ascii=False))

if __name__=="__main__":
    main()
PY

chmod 755 "$RES"
python3 -m py_compile "$RES"
echo DEPENDENCY_RESOLVER_V2_SOURCE_OK

echo "=== 2. KILL ONLY OLD V1 RESOLVER IF STILL RUNNING ==="
OLD=$(pgrep -f 'python3 /home/ubuntu/Central/dependency_resolver_v1/resolve_android_dependencies.py 20260922-235547-f-droid-apk-eced82' || true)
if [ -n "$OLD" ]; then
  echo "old_pids=$OLD"
  kill $OLD 2>/dev/null || true
  sleep 1
fi
echo DEPENDENCY_RESOLVER_OLD_RUN_STOPPED_OK

echo "=== 3. RETEST LATEST REAL PROJECT WITH TIMING ==="
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
START=$(date +%s)
OUT=$(sudo -u ubuntu python3 "$RES" "$LATEST")
END=$(date +%s)
printf '%s\n' "$OUT"
ELAPSED=$((END-START))
echo "elapsed_sec=$ELAPSED"
printf '%s\n' "$OUT" | tail -n1 | python3 -c 'import json,sys;x=json.load(sys.stdin);assert x["ok"] is True; assert x["component_count"]>=1'
echo DEPENDENCY_RESOLVER_V2_REAL_PROJECT_OK

echo CENTRAL_DEPENDENCY_RESOLVER_V2_READY
echo "backup=$BACKUP"
