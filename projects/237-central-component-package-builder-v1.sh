#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/component_package_builder_v1
RES=/home/ubuntu/Central/dependency_resolver_v1/resolve_android_dependencies.py
UI=/home/ubuntu/Central/auditor_ui_v1/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/component-package-builder-v1-$STAMP
mkdir -p "$ROOT" "$BACKUP"
cp -a "$UI" "$BACKUP/server.py.before"

echo "=== 1. INSTALL COMPONENT PACKAGE BUILDER V1 ==="
cat >"$ROOT/build_component_package.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, shutil, re
from pathlib import Path

PROJECTS=Path("/home/ubuntu/Central/projects")

def safe_name(s):
    return re.sub(r"[^A-Za-z0-9._-]+","_",s)

def copy_rel(src_root:Path, rel:str, dst_root:Path):
    src=src_root/rel
    if not src.is_file():
        return False
    dst=dst_root/rel
    dst.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(src,dst)
    return True

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("project_id")
    ap.add_argument("role")
    args=ap.parse_args()

    root=PROJECTS/args.project_id
    pkg_json=root/"work"/"dependencies"/safe_name(args.role)/"package.json"
    decoded=root/"work"/"android-audit"/"decoded"
    if not pkg_json.is_file():raise SystemExit("PACKAGE_JSON_NOT_FOUND")
    if not decoded.is_dir():raise SystemExit("DECODED_TREE_NOT_FOUND")

    pkg=json.load(open(pkg_json,encoding="utf-8"))
    out=root/"work"/"component-packages"/safe_name(args.role)
    if out.exists():shutil.rmtree(out)
    for d in ["CORE","DEPENDENCIES/SHARED","DEPENDENCIES/EXTERNAL","DEPENDENCIES/FRAMEWORK","RESOURCES","APIS"]:
        (out/d).mkdir(parents=True,exist_ok=True)

    class_rows=pkg.get("classification") or []
    copied={"CORE":0,"DIRECT":0,"TRANSITIVE":0,"SHARED":0,"EXTERNAL":0,"FRAMEWORK":0}
    missing=[]

    # Map descriptor to smali source by scanning once.
    desc_to_rel={}
    for p in decoded.rglob("*.smali"):
        rel=str(p.relative_to(decoded))
        try:
            head=p.read_text(encoding="utf-8",errors="ignore")[:800]
        except Exception:
            continue
        m=re.search(r'^\.class\s+.*?\s+(L[^;]+;)',head,re.M)
        if m:desc_to_rel[m.group(1)]=rel

    for row in class_rows:
        d=row.get("descriptor")
        kind=row.get("kind")
        rel=desc_to_rel.get(d)
        if not rel:
            missing.append({"descriptor":d,"kind":kind});continue
        if kind=="CORE":
            target=out/"CORE"
        elif kind in {"DIRECT","TRANSITIVE"}:
            target=out/"DEPENDENCIES"/"SHARED"
        elif kind=="SHARED":
            target=out/"DEPENDENCIES"/"SHARED"
        elif kind=="EXTERNAL":
            target=out/"DEPENDENCIES"/"EXTERNAL"
        elif kind=="FRAMEWORK":
            target=out/"DEPENDENCIES"/"FRAMEWORK"
        else:
            target=out/"DEPENDENCIES"/"SHARED"
        if copy_rel(decoded,rel,target):
            copied[kind]=copied.get(kind,0)+1

    resource_copied=0
    for rel in pkg.get("resources") or []:
        if copy_rel(decoded,rel,out/"RESOURCES"):
            resource_copied+=1

    apis=pkg.get("external_api_bases") or []
    (out/"APIS"/"apis.json").write_text(json.dumps(apis,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    manifest={
      "schema_version":"central.component-bundle.v1",
      "project_id":args.project_id,
      "component_id":pkg.get("component_id"),
      "name":pkg.get("name"),
      "role":pkg.get("role"),
      "confidence":pkg.get("confidence"),
      "reuse_assessment":pkg.get("reuse_assessment"),
      "export_strategy":pkg.get("export_strategy"),
      "source_copy_included":True,
      "counts":{
        "core":copied.get("CORE",0),
        "direct":copied.get("DIRECT",0),
        "transitive":copied.get("TRANSITIVE",0),
        "shared":copied.get("SHARED",0),
        "external":copied.get("EXTERNAL",0),
        "framework":copied.get("FRAMEWORK",0),
        "resources":resource_copied,
        "apis":len(apis),
        "missing_classes":len(missing)
      },
      "permissions":pkg.get("permissions") or [],
      "missing_classes":missing,
      "source_package_json":str(pkg_json),
      "notes":[
        "Este bundle es evidencia técnica extraída, no una app ejecutable.",
        "CORE contiene clases núcleo detectadas para el componente.",
        "DEPENDENCIES separa dependencias compartidas, externas y de framework.",
        "La etapa siguiente evalúa reconstrucción limpia y contratos de entrada/salida."
      ]
    }
    (out/"manifest.json").write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    readme=f"""# {pkg.get('name')}

Rol: {pkg.get('role')}
Proyecto: {args.project_id}
Confianza: {pkg.get('confidence')}
Reutilización: {pkg.get('reuse_assessment')}
Estrategia sugerida: {pkg.get('export_strategy')}

## Contenido
- CORE/: clases núcleo
- DEPENDENCIES/SHARED/: dependencias internas compartidas
- DEPENDENCIES/EXTERNAL/: librerías externas
- DEPENDENCIES/FRAMEWORK/: Android/Java/Kotlin framework
- RESOURCES/: recursos asociados
- APIS/apis.json: bases API detectadas
- manifest.json: inventario técnico del bundle

## Importante
Este paquete no se considera ejecutable ni portable por sí solo. Es una pieza técnica para análisis, adaptación o reconstrucción limpia.
"""
    (out/"README.md").write_text(readme,encoding="utf-8")

    result={"ok":True,"project_id":args.project_id,"role":args.role,"bundle_path":str(out),"manifest":manifest}
    print(json.dumps(result,ensure_ascii=False))

if __name__=="__main__":
    main()
PY
chmod 755 "$ROOT/build_component_package.py"
python3 -m py_compile "$ROOT/build_component_package.py"
echo COMPONENT_PACKAGE_BUILDER_V1_SOURCE_OK

echo "=== 2. BUILD STREAM RESOLUTION BUNDLE FROM LATEST PROJECT ==="
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
OUT=$(sudo -u ubuntu python3 "$ROOT/build_component_package.py" "$LATEST" stream_resolution)
echo "$OUT"
python3 - "$OUT" <<'PY'
import json,sys,os
x=json.loads(sys.argv[1])
assert x["ok"] is True
m=x["manifest"]["counts"]
assert m["core"]>=1
assert os.path.isfile(os.path.join(x["bundle_path"],"manifest.json"))
assert os.path.isfile(os.path.join(x["bundle_path"],"README.md"))
print("COMPONENT_PACKAGE_STREAMS_REAL_PROJECT_OK")
print("bundle="+x["bundle_path"])
print("counts="+json.dumps(m,ensure_ascii=False))
PY

echo "=== 3. ADD BUNDLE ENDPOINT + UI ACTION ==="
python3 - "$UI" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

if '/bundle/"' not in s:
    anchor='''        m=re.fullmatch(r"/api/runs/([A-Za-z0-9_-]+)/dependencies",p)
'''
    insert='''        m=re.fullmatch(r"/api/runs/([A-Za-z0-9_-]+)/bundle/([A-Za-z0-9._-]+)",p)
        if m:
            r=get_run(m.group(1))
            if not r:return self.send_json(404,{"ok":False,"error":"RUN_NOT_FOUND"})
            pid=r.get("project_id")
            if not pid:return self.send_json(409,{"ok":False,"error":"PROJECT_NOT_READY"})
            fp=Path("/home/ubuntu/Central/projects")/pid/"work"/"component-packages"/m.group(2)/"manifest.json"
            if not fp.is_file():return self.send_json(404,{"ok":False,"error":"BUNDLE_NOT_READY"})
            try:return self.send_json(200,json.loads(fp.read_text(encoding="utf-8")))
            except Exception as e:return self.send_json(500,{"ok":False,"error":"BUNDLE_READ_FAILED","detail":str(e)})

'''
    if anchor not in s:raise SystemExit("BUNDLE_ENDPOINT_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert+anchor,1)

if 'async function loadBundle(' not in s:
    anchor='''async function loadDependencies(rid){
'''
    func='''async function loadBundle(rid,role){
 const box=$('#dependencies')
 try{
   const x=await api('api/runs/'+rid+'/bundle/'+role,{},4000)
   const c=x.counts||{}
   alert((x.name||role)+'\nCORE '+(c.core||0)+'\nCompartidas '+(c.shared||0)+'\nExternas '+(c.external||0)+'\nFramework '+(c.framework||0)+'\nRecursos '+(c.resources||0)+'\nAPIs '+(c.apis||0))
 }catch(e){alert('Bundle todavía no disponible para '+role)}
}
'''
    if anchor not in s:raise SystemExit("BUNDLE_UI_FUNC_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,func+anchor,1)

# Make dependency rows clickable to inspect already-built bundles.
old="""     const b=document.createElement('span');b.className='badge';b.textContent=c.reuse_assessment||'—'
     d.append(l,b);box.appendChild(d)
"""
new="""     const b=document.createElement('button');b.className='badge';b.textContent=c.reuse_assessment||'—';b.onclick=()=>loadBundle(rid,c.role)
     d.append(l,b);box.appendChild(d)
"""
if old in s:s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$UI"
echo COMPONENT_PACKAGE_BUILDER_UI_SOURCE_OK

echo "=== 4. RESTART UI + PUBLIC CHECK ==="
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8792/api/health >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo COMPONENT_PACKAGE_BUILDER_PUBLIC_UI_OK

echo CENTRAL_COMPONENT_PACKAGE_BUILDER_V1_READY
echo "project_tested=$LATEST"
echo "backup=$BACKUP"
