#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/dependency_resolver_v1
PIPE=/home/ubuntu/Central/pipeline_v1/run_android_pipeline.py
UI=/home/ubuntu/Central/auditor_ui_v1/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/dependency-resolver-v1-$STAMP
mkdir -p "$ROOT" "$BACKUP"
cp -a "$PIPE" "$BACKUP/run_android_pipeline.py.before"
cp -a "$UI" "$BACKUP/server.py.before"

echo "=== 1. INSTALL DEPENDENCY RESOLVER V1 ==="
cat >"$ROOT/resolve_android_dependencies.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, hashlib, json, re
from collections import deque
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

def read_text(p):
    try:return p.read_text(encoding="utf-8",errors="ignore")
    except Exception:return ""

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

    smali_files=[]
    class_map={}
    file_to_class={}
    for p in decoded.rglob("*.smali"):
        if not p.is_file(): continue
        smali_files.append(p)
        txt=read_text(p)
        m=CLASS_RE.search(txt)
        if m:
            d=m.group(1)
            class_map[d]=p
            file_to_class[p]=d

    evidence={e.get("id"):e for e in analysis.get("evidence",[]) if isinstance(e,dict)}
    canon_components={c.get("id"):c for c in analysis.get("components",[]) if isinstance(c,dict)}

    out_root=root/"work"/"dependencies"
    out_root.mkdir(parents=True,exist_ok=True)

    resolved=[]
    for csum in components:
        cid=csum["id"]
        role=csum["role"]
        canon=canon_components.get(cid) or {}
        members=set(canon.get("members") or [])
        evrefs=canon.get("evidence_refs") or []

        seed_files=set()
        seed_classes=set()

        # Exact member/evidence matches first.
        member_texts=list(members)
        for eid in evrefs:
            ev=evidence.get(eid)
            if ev:
                member_texts += [str(ev.get("locator") or ""),str(ev.get("excerpt") or "")]

        for text in member_texts:
            if not text: continue
            low=text.lower()
            for p,d in file_to_class.items():
                rel=str(p.relative_to(decoded))
                dotted=descriptor_to_dotted(d)
                if rel in text or dotted in text or d in text:
                    seed_files.add(p);seed_classes.add(d)

        # If semantic evidence did not directly map to smali, score files by role keywords.
        if len(seed_files)<3:
            kws=ROLE_WORDS.get(role,[])
            scored=[]
            for p in smali_files:
                txt=read_text(p).lower()
                score=sum(txt.count(k) for k in kws)
                if score:
                    scored.append((score,p))
            scored.sort(key=lambda x:(-x[0],str(x[1])))
            for _,p in scored[:20]:
                seed_files.add(p)
                d=file_to_class.get(p)
                if d: seed_classes.add(d)

        # BFS closure through same-APK class references.
        closure=set(seed_classes)
        direct=set()
        q=deque((d,0) for d in seed_classes)
        while q and len(closure)<args.max_classes:
            d,depth=q.popleft()
            p=class_map.get(d)
            if not p: continue
            txt=read_text(p)
            refs={r for r in REF_RE.findall(txt) if r in class_map and r!=d}
            if depth==0: direct.update(refs)
            if depth>=args.depth: continue
            for r in refs:
                if r not in closure:
                    closure.add(r)
                    q.append((r,depth+1))
                    if len(closure)>=args.max_classes: break

        files=[class_map[d] for d in closure if d in class_map]
        resources=set()
        resource_refs=set()
        for p in files:
            txt=read_text(p)
            for r in RES_RE.findall(txt):
                resource_refs.add(r)

        # Resolve named resource identifiers conservatively through decoded resources.
        if resource_refs:
            for p in decoded.rglob("*"):
                if not p.is_file() or "/res/" not in str(p): continue
                name=p.stem.lower()
                if any(name in rr.lower() for rr in resource_refs if not rr.lower().startswith("0x7f")):
                    resources.add(str(p.relative_to(decoded)))

        perms=list((analysis.get("security") or {}).get("permissions") or [])
        apis=[]
        for api in (analysis.get("data") or {}).get("apis",[]):
            txt=json.dumps(api,ensure_ascii=False).lower()
            if any(k in txt for k in ROLE_WORDS.get(role,[])):
                apis.append(api.get("base"))

        package={
            "schema_version":"central.component-package.v1",
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
            "limits":{
                "depth":args.depth,
                "max_classes":args.max_classes,
                "closure_truncated":len(closure)>=args.max_classes
            },
            "export_strategy":"reconstruct_clean" if csum.get("reuse_assessment")=="rebuild_recommended" else "adapt_or_reconstruct",
            "source_copy_included":False
        }

        safe=re.sub(r"[^A-Za-z0-9._-]+","_",role)
        pkgdir=out_root/safe
        pkgdir.mkdir(parents=True,exist_ok=True)
        (pkgdir/"package.json").write_text(json.dumps(package,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

        summary={
            "id":cid,
            "name":csum.get("name"),
            "role":role,
            "confidence":csum.get("confidence"),
            "reuse_assessment":csum.get("reuse_assessment"),
            "seed_count":len(seed_classes),
            "direct_dependency_count":len(direct),
            "closure_count":len(closure),
            "resource_count":len(resources),
            "api_count":len(package["external_api_bases"]),
            "closure_truncated":package["limits"]["closure_truncated"],
            "package_path":str(pkgdir/"package.json")
        }
        resolved.append(summary)

    result={
        "ok":True,
        "project_id":args.project_id,
        "component_count":len(resolved),
        "components":resolved
    }
    (out_root/"summary.json").write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(result,ensure_ascii=False))

if __name__=="__main__":
    main()
PY
chmod 755 "$ROOT/resolve_android_dependencies.py"
python3 -m py_compile "$ROOT/resolve_android_dependencies.py"
echo DEPENDENCY_RESOLVER_V1_SOURCE_OK

echo "=== 2. INTEGRATE RESOLVER INTO PIPELINE ==="
python3 - "$PIPE" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

if 'RESOLVER=Path("/home/ubuntu/Central/dependency_resolver_v1/resolve_android_dependencies.py")' not in s:
    s=s.replace(
        'COMPONENTIZER=Path("/home/ubuntu/Central/componentizer_v1/componentize_android.py")\n',
        'COMPONENTIZER=Path("/home/ubuntu/Central/componentizer_v1/componentize_android.py")\nRESOLVER=Path("/home/ubuntu/Central/dependency_resolver_v1/resolve_android_dependencies.py")\n',
        1
    )

old='''        componentization=parse_last_json(out_c)

    stage(10,"Verificando salida final")

    overall_ok=(deobf_status!="FAILED")
'''
new='''        componentization=parse_last_json(out_c)
        rc_d,out_d,err_d=run(["python3",str(RESOLVER),pid])
        if rc_d!=0:
            print(json.dumps({"ok":False,"stage":"dependency_resolution","project_id":pid,"stdout":out_d,"stderr":err_d},ensure_ascii=False),flush=True)
            raise SystemExit(rc_d or 2)
        dependency_resolution=parse_last_json(out_d)
    else:
        dependency_resolution=None

    stage(10,"Verificando salida final")

    overall_ok=(deobf_status!="FAILED")
'''
if old not in s:
    raise SystemExit("RESOLVER_PIPE_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

old='''        "componentization":componentization,
        "analysis_path":str(PROJECTS/pid/"canon"/"analysis.json")
'''
new='''        "componentization":componentization,
        "dependency_resolution":dependency_resolution,
        "analysis_path":str(PROJECTS/pid/"canon"/"analysis.json")
'''
if old not in s:
    raise SystemExit("RESOLVER_PIPE_RESULT_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$PIPE"
echo DEPENDENCY_RESOLVER_PIPELINE_OK

echo "=== 3. ADD DEPENDENCY ENDPOINT + UI DETAILS ==="
python3 - "$UI" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

if '/dependencies"' not in s:
    anchor='''        m=re.fullmatch(r"/api/runs/([A-Za-z0-9_-]+)/components",p)
'''
    insert='''        m=re.fullmatch(r"/api/runs/([A-Za-z0-9_-]+)/dependencies",p)
        if m:
            r=get_run(m.group(1))
            if not r:return self.send_json(404,{"ok":False,"error":"RUN_NOT_FOUND"})
            pid=r.get("project_id")
            if not pid:return self.send_json(409,{"ok":False,"error":"PROJECT_NOT_READY"})
            fp=Path("/home/ubuntu/Central/projects")/pid/"work"/"dependencies"/"summary.json"
            if not fp.is_file():return self.send_json(404,{"ok":False,"error":"DEPENDENCIES_NOT_READY"})
            try:return self.send_json(200,json.loads(fp.read_text(encoding="utf-8")))
            except Exception as e:return self.send_json(500,{"ok":False,"error":"DEPENDENCIES_READ_FAILED","detail":str(e)})

'''
    s=s.replace(anchor,insert+anchor,1)

if 'id="dependencies"' not in s:
    anchor='''  <div class="card">
    <strong>Log en vivo</strong>
'''
    insert='''  <div class="card">
    <strong>Piezas y dependencias</strong>
    <div id="dependencies" class="meta">Se calcularán al terminar el análisis.</div>
  </div>

'''
    s=s.replace(anchor,insert+anchor,1)

if 'async function loadDependencies(' not in s:
    anchor='''async function loadComponents(rid){
'''
    func='''async function loadDependencies(rid){
 const box=$('#dependencies')
 if(!box)return
 try{
   const x=await api('api/runs/'+rid+'/dependencies',{},4000)
   const cs=x.components||[]
   if(!cs.length){box.textContent='No hay cierres de dependencias disponibles.';return}
   box.innerHTML=''
   for(const c of cs){
     const d=document.createElement('div');d.className='run'
     const l=document.createElement('div')
     const trunc=c.closure_truncated?' · límite alcanzado':''
     l.innerHTML='<div><strong>'+c.name+'</strong></div><small>núcleo '+c.seed_count+' · directas '+c.direct_dependency_count+' · cierre '+c.closure_count+' clases · recursos '+c.resource_count+' · APIs '+c.api_count+trunc+'</small>'
     const b=document.createElement('span');b.className='badge';b.textContent=c.reuse_assessment||'—'
     d.append(l,b);box.appendChild(d)
   }
 }catch(e){box.textContent='Dependencias todavía no disponibles.'}
}
'''
    s=s.replace(anchor,func+anchor,1)

old="""     if(r.status==='COMPLETED')loadComponents(active)
"""
new="""     if(r.status==='COMPLETED'){loadComponents(active);loadDependencies(active)}
"""
if old in s:
    s=s.replace(old,new,1)

old2="""b.onclick=()=>{active=r.id;watch();if(r.status==='COMPLETED')loadComponents(r.id)}
"""
new2="""b.onclick=()=>{active=r.id;watch();if(r.status==='COMPLETED'){loadComponents(r.id);loadDependencies(r.id)}}
"""
if old2 in s:
    s=s.replace(old2,new2,1)

p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$UI"
echo DEPENDENCY_RESOLVER_UI_SOURCE_OK

echo "=== 4. TEST ON LATEST REAL COMPLETED PROJECT ==="
LATEST=$(python3 - <<'PY'
import json
from pathlib import Path
rows=json.load(open("/home/ubuntu/Central/auditor_ui_v1/data/runs.json",encoding="utf-8"))
for r in rows:
    if r.get("status")=="COMPLETED" and r.get("project_id"):
        print(r["project_id"]);break
PY
)
test -n "$LATEST"
echo "project=$LATEST"
OUT=$(sudo -u ubuntu python3 "$ROOT/resolve_android_dependencies.py" "$LATEST")
echo "$OUT"
COUNT=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["component_count"])' <<<"$OUT")
test "$COUNT" -ge 1
python3 - "$OUT" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert all(c["closure_count"]>=c["seed_count"] for c in x["components"]),x
assert all(c["package_path"] for c in x["components"]),x
print("DEPENDENCY_RESOLVER_REAL_PROJECT_OK")
PY

echo "=== 5. RESTART UI + PUBLIC CHECK ==="
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8792/api/health >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo DEPENDENCY_RESOLVER_PUBLIC_UI_OK

echo CENTRAL_DEPENDENCY_RESOLVER_V1_READY
echo "project_tested=$LATEST"
echo "backup=$BACKUP"
