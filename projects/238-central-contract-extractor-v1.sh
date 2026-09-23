#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/contract_extractor_v1
UI=/home/ubuntu/Central/auditor_ui_v1/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/contract-extractor-v1-$STAMP
mkdir -p "$ROOT" "$BACKUP"
cp -a "$UI" "$BACKUP/server.py.before"

echo "=== 1. INSTALL CONTRACT EXTRACTOR V1 ==="
cat >"$ROOT/extract_component_contract.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, re
from collections import Counter, defaultdict
from pathlib import Path

PROJECTS=Path("/home/ubuntu/Central/projects")

METHOD_RE=re.compile(r'^\.method\s+(.*?)\((.*?)\)(\S+)\s*$',re.M)
INVOKE_RE=re.compile(r'invoke-[^\s]+\s+\{[^}]*\},\s+(L[^;]+;)->([^\(]+)\(([^)]*)\)(\S+)')
FIELD_RE=re.compile(r'(L[^;]+;)->([A-Za-z0-9_$]+):([^\s]+)')
CONST_STR_RE=re.compile(r'const-string(?:/jumbo)?\s+v\d+,\s+"(.*?)"')
PERM_HINTS={
 "android.permission.INTERNET":["http://","https://","okhttp","retrofit","socket","urlconnection","uri"],
 "android.permission.ACCESS_NETWORK_STATE":["connectivitymanager","networkinfo","networkcapabilities"],
 "android.permission.ACCESS_WIFI_STATE":["wifimanager","wifiinfo"],
 "android.permission.BLUETOOTH":["bluetooth"],
 "android.permission.BLUETOOTH_CONNECT":["bluetooth"],
 "android.permission.BLUETOOTH_SCAN":["bluetooth","scan"],
 "android.permission.CAMERA":["camera","camerax"],
 "android.permission.NFC":["nfc"],
 "android.permission.READ_EXTERNAL_STORAGE":["externalstorage","environment","fileinputstream"],
 "android.permission.WRITE_EXTERNAL_STORAGE":["externalstorage","environment","fileoutputstream"],
 "android.permission.MANAGE_EXTERNAL_STORAGE":["externalstorage","environment","managestorage"],
 "android.permission.WAKE_LOCK":["wakelock","powermanager"],
}

def parse_type(sig:str):
    # coarse descriptor parser
    out=[]
    i=0
    while i<len(sig):
        c=sig[i]
        if c in "ZBCSIJFDV":
            out.append(c);i+=1
        elif c=="L":
            j=sig.find(";",i)
            if j<0:break
            out.append(sig[i:j+1]);i=j+1
        elif c=="[":
            j=i
            while j<len(sig) and sig[j]=="[":j+=1
            if j<len(sig) and sig[j]=="L":
                k=sig.find(";",j)
                if k<0:break
                out.append(sig[i:k+1]);i=k+1
            else:
                out.append(sig[i:j+1]);i=j+1
        else:i+=1
    return out

def dotted(d):
    if d.startswith("L") and d.endswith(";"):
        return d[1:-1].replace("/",".")
    return d

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("project_id")
    ap.add_argument("role")
    args=ap.parse_args()

    root=PROJECTS/args.project_id
    bundle=root/"work"/"component-packages"/args.role
    manifest_path=bundle/"manifest.json"
    dep_pkg=root/"work"/"dependencies"/args.role/"package.json"
    decoded=root/"work"/"android-audit"/"decoded"
    if not manifest_path.is_file():raise SystemExit("BUNDLE_MANIFEST_NOT_FOUND")
    if not dep_pkg.is_file():raise SystemExit("DEPENDENCY_PACKAGE_NOT_FOUND")
    if not decoded.is_dir():raise SystemExit("DECODED_TREE_NOT_FOUND")

    manifest=json.load(open(manifest_path,encoding="utf-8"))
    dep=json.load(open(dep_pkg,encoding="utf-8"))

    core_files=list((bundle/"CORE").rglob("*.smali"))
    if not core_files:raise SystemExit("CORE_EMPTY")

    methods=[]
    inputs=Counter(); outputs=Counter(); external_calls=Counter()
    strings=[]; used_permission_evidence=defaultdict(list)
    network_hosts=set()
    for p in core_files:
        txt=p.read_text(encoding="utf-8",errors="ignore")
        rel=str(p.relative_to(bundle))
        low=txt.lower()

        for m in METHOD_RE.finditer(txt):
            mods=m.group(1)
            params=m.group(2)
            ret=m.group(3)
            ptypes=parse_type(params)
            rtypes=parse_type(ret)
            methods.append({
                "file":rel,
                "signature":m.group(0).strip(),
                "parameter_types":[dotted(x) for x in ptypes],
                "return_type":dotted(rtypes[0]) if rtypes else ret
            })
            for t in ptypes:inputs[dotted(t)]+=1
            if ret!="V":
                for t in rtypes or [ret]:outputs[dotted(t)]+=1

        for inv in INVOKE_RE.finditer(txt):
            owner,name,params,ret=inv.groups()
            if not owner.startswith(("Ljava/","Landroid/","Landroidx/","Lkotlin/","Lkotlinx/")):
                external_calls[f"{dotted(owner)}->{name}"]+=1

        for s in CONST_STR_RE.findall(txt):
            strings.append({"file":rel,"value":s})
            for url in re.findall(r'https?://[^\s"\']+',s):
                network_hosts.add(url.split("/")[2] if "/" in url[8:] else url)
        for perm,hints in PERM_HINTS.items():
            for h in hints:
                if h in low:
                    used_permission_evidence[perm].append({"file":rel,"hint":h})
                    break

    declared=set(manifest.get("permissions") or [])
    permission_contract=[]
    for perm in sorted(declared):
        ev=used_permission_evidence.get(perm,[])
        permission_contract.append({
            "permission":perm,
            "status":"supported_by_core" if ev else "not_observed_in_core",
            "evidence":ev[:10]
        })

    api_bases=dep.get("external_api_bases") or []
    contract={
      "schema_version":"central.component-contract.v1",
      "project_id":args.project_id,
      "component_id":manifest.get("component_id"),
      "name":manifest.get("name"),
      "role":args.role,
      "core_class_count":manifest.get("counts",{}).get("core",0),
      "inputs":[{"type":k,"occurrences":v} for k,v in inputs.most_common(30)],
      "outputs":[{"type":k,"occurrences":v} for k,v in outputs.most_common(30)],
      "public_method_observations":methods[:300],
      "external_calls":[{"target":k,"occurrences":v} for k,v in external_calls.most_common(100)],
      "network":{
        "declared_api_bases":api_bases,
        "hosts_observed_in_core":sorted(network_hosts),
        "uses_network_indicators":bool(api_bases or network_hosts or used_permission_evidence.get("android.permission.INTERNET"))
      },
      "permissions":permission_contract,
      "summary":{
        "declared_permission_count":len(declared),
        "supported_permission_count":sum(1 for x in permission_contract if x["status"]=="supported_by_core"),
        "observed_input_type_count":len(inputs),
        "observed_output_type_count":len(outputs),
        "external_call_count":sum(external_calls.values())
      },
      "notes":[
        "V1 infiere contratos a partir de firmas smali y uso observable dentro de CORE.",
        "not_observed_in_core no significa que el permiso sea imposible; significa que no apareció evidencia directa en las clases núcleo.",
        "La etapa siguiente puede reconstruir una interfaz limpia basada en estos contratos observados."
      ]
    }

    out=bundle/"CONTRACT"
    out.mkdir(parents=True,exist_ok=True)
    (out/"contract.json").write_text(json.dumps(contract,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    # Tighten bundle manifest with component-specific permission evidence.
    manifest["contract_path"]=str(out/"contract.json")
    manifest["permission_contract"]={
      "supported":[x["permission"] for x in permission_contract if x["status"]=="supported_by_core"],
      "not_observed":[x["permission"] for x in permission_contract if x["status"]=="not_observed_in_core"]
    }
    manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    result={"ok":True,"project_id":args.project_id,"role":args.role,"contract_path":str(out/"contract.json"),"contract":contract}
    print(json.dumps(result,ensure_ascii=False))

if __name__=="__main__":
    main()
PY
chmod 755 "$ROOT/extract_component_contract.py"
python3 -m py_compile "$ROOT/extract_component_contract.py"
echo CONTRACT_EXTRACTOR_V1_SOURCE_OK

echo "=== 2. TEST ON STREAM RESOLUTION BUNDLE ==="
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
OUT=$(sudo -u ubuntu python3 "$ROOT/extract_component_contract.py" "$LATEST" stream_resolution)
echo "$OUT"
python3 - "$OUT" <<'PY'
import json,sys,os
x=json.loads(sys.argv[1])
assert x["ok"] is True
c=x["contract"]
assert c["core_class_count"]>=1
assert os.path.isfile(x["contract_path"])
print("CONTRACT_EXTRACTOR_STREAMS_REAL_PROJECT_OK")
print("summary="+json.dumps(c["summary"],ensure_ascii=False))
print("network="+json.dumps(c["network"],ensure_ascii=False))
print("supported_permissions="+json.dumps([p["permission"] for p in c["permissions"] if p["status"]=="supported_by_core"],ensure_ascii=False))
PY

echo "=== 3. ADD CONTRACT ENDPOINT + UI DETAIL ==="
python3 - "$UI" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

if '/contract/"' not in s:
    anchor='''        m=re.fullmatch(r"/api/runs/([A-Za-z0-9_-]+)/bundle/([A-Za-z0-9._-]+)",p)
'''
    insert='''        m=re.fullmatch(r"/api/runs/([A-Za-z0-9_-]+)/contract/([A-Za-z0-9._-]+)",p)
        if m:
            r=get_run(m.group(1))
            if not r:return self.send_json(404,{"ok":False,"error":"RUN_NOT_FOUND"})
            pid=r.get("project_id")
            if not pid:return self.send_json(409,{"ok":False,"error":"PROJECT_NOT_READY"})
            fp=Path("/home/ubuntu/Central/projects")/pid/"work"/"component-packages"/m.group(2)/"CONTRACT"/"contract.json"
            if not fp.is_file():return self.send_json(404,{"ok":False,"error":"CONTRACT_NOT_READY"})
            try:return self.send_json(200,json.loads(fp.read_text(encoding="utf-8")))
            except Exception as e:return self.send_json(500,{"ok":False,"error":"CONTRACT_READ_FAILED","detail":str(e)})

'''
    if anchor not in s:raise SystemExit("CONTRACT_ENDPOINT_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert+anchor,1)

if 'async function loadContract(' not in s:
    anchor='''async function loadBundle(rid,role){
'''
    func='''async function loadContract(rid,role){
 try{
   const x=await api('api/runs/'+rid+'/contract/'+role,{},4000)
   const s=x.summary||{},n=x.network||{}
   const ps=(x.permissions||[]).filter(p=>p.status==='supported_by_core').map(p=>p.permission)
   alert((x.name||role)+'\nEntradas '+(s.observed_input_type_count||0)+'\nSalidas '+(s.observed_output_type_count||0)+'\nLlamadas externas '+(s.external_call_count||0)+'\nRed '+(n.uses_network_indicators?'sí':'no')+'\nPermisos observados '+ps.length+'\n'+ps.join('\n'))
 }catch(e){alert('Contrato todavía no disponible para '+role)}
}
'''
    if anchor not in s:raise SystemExit("CONTRACT_UI_FUNC_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,func+anchor,1)

old="""     const b=document.createElement('button');b.className='badge';b.textContent=c.reuse_assessment||'—';b.onclick=()=>loadBundle(rid,c.role)
"""
new="""     const b=document.createElement('button');b.className='badge';b.textContent=c.reuse_assessment||'—';b.onclick=()=>loadContract(rid,c.role)
"""
if old in s:s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$UI"
echo CONTRACT_EXTRACTOR_UI_SOURCE_OK

echo "=== 4. RESTART UI + PUBLIC CHECK ==="
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8792/api/health >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo CONTRACT_EXTRACTOR_PUBLIC_UI_OK

echo CENTRAL_CONTRACT_EXTRACTOR_V1_READY
echo "project_tested=$LATEST"
echo "backup=$BACKUP"
