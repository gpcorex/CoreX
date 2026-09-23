#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/componentizer_v1
PIPE=/home/ubuntu/Central/pipeline_v1/run_android_pipeline.py
UI=/home/ubuntu/Central/auditor_ui_v1/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/componentizer-v1-$STAMP
mkdir -p "$ROOT" "$BACKUP"
cp -a "$PIPE" "$BACKUP/run_android_pipeline.py.before"
cp -a "$UI" "$BACKUP/server.py.before"

echo "=== 1. INSTALL FUNCTIONAL COMPONENTIZER V1 ==="
cat >"$ROOT/componentize_android.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, hashlib, json, re
from collections import defaultdict
from pathlib import Path

PROJECTS=Path("/home/ubuntu/Central/projects")

ROLES={
  "catalog": ["catalog","catalogue","browse","listing","feed","repository list","product list"],
  "search": ["search","query","filter","find","autocomplete"],
  "detail": ["detail","details","movie detail","episode detail","item detail"],
  "player": ["player","playback","exoplayer","mediaplayer","video view","play video"],
  "stream_resolution": ["m3u8","mpd","dash","hls","stream","playlist","manifest"],
  "subtitles": ["subtitle","subtitles","caption","captions","vtt","srt"],
  "authentication": ["login","signin","sign in","auth","oauth","token","session","jwt"],
  "favorites": ["favorite","favourite","bookmark","watchlist","liked"],
  "downloads": ["download","offline","cache media"],
  "profiles": ["profile","account","user profile"],
  "ads": ["admob","advert","ads","doubleclick","interstitial"],
  "analytics": ["analytics","firebaseanalytics","telemetry","crashlytics","sentry"],
  "settings": ["settings","preferences","configuration"],
  "navigation": ["navigation","navcontroller","router","deeplink","deep link"],
  "data_source": ["api","endpoint","retrofit","okhttp","graphql","repository","datasource","http"]
}

DISPLAY={
  "catalog":"Catálogo",
  "search":"Búsqueda",
  "detail":"Detalle",
  "player":"Reproductor",
  "stream_resolution":"Resolución de streams",
  "subtitles":"Subtítulos",
  "authentication":"Autenticación",
  "favorites":"Favoritos",
  "downloads":"Descargas",
  "profiles":"Perfiles",
  "ads":"Publicidad",
  "analytics":"Analítica",
  "settings":"Configuración",
  "navigation":"Navegación",
  "data_source":"Fuente de datos"
}

def norm(s):
    return re.sub(r"\s+"," ",str(s or "").lower())

def confidence(score):
    if score>=18:return "verified"
    if score>=10:return "high"
    if score>=5:return "medium"
    return "low"

def reuse(score,role):
    if role in {"ads","analytics"}:
        return "not_reusable"
    if score>=14:
        return "adaptable"
    if score>=7:
        return "rebuild_recommended"
    return "unknown"

def add_evidence(a,kind,locator,excerpt,tool="central-componentizer-v1"):
    eid="ev."+hashlib.sha1((kind+"|"+locator+"|"+excerpt).encode("utf-8","replace")).hexdigest()[:12]
    if not any(e.get("id")==eid for e in a.get("evidence",[])):
        a.setdefault("evidence",[]).append({
            "id":eid,
            "kind":kind,
            "locator":locator,
            "excerpt":excerpt[:1000],
            "hash_sha256":None,
            "tool":tool,
            "observed_at":None
        })
    return eid

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("project_id")
    args=ap.parse_args()

    root=PROJECTS/args.project_id
    analysis_path=root/"canon"/"analysis.json"
    if not analysis_path.is_file():
        raise SystemExit("ANALYSIS_NOT_FOUND")
    a=json.load(open(analysis_path,encoding="utf-8"))

    deobf=root/"work"/"deobfuscation"
    interesting=[]
    if (deobf/"interesting-strings.json").is_file():
        interesting=json.load(open(deobf/"interesting-strings.json",encoding="utf-8"))

    routines=[]
    if (deobf/"decoder-routines.json").is_file():
        routines=json.load(open(deobf/"decoder-routines.json",encoding="utf-8"))

    # Candidate textual evidence from interfaces, behaviors, APIs, recovered strings and evidence.
    sources=[]
    for x in a.get("interfaces",[]):
        sources.append(("interface",x.get("name",""),x.get("id"),3))
    for x in a.get("behaviors",[]):
        sources.append(("behavior",x.get("name",""),x.get("id"),2))
    for x in (a.get("data") or {}).get("apis",[]):
        txt=" ".join([x.get("base","")]+list(x.get("endpoints") or []))
        sources.append(("api",txt,x.get("id"),4))
    for row in interesting[:50000]:
        txt=row.get("decoded","")
        src=row.get("source","")
        sources.append(("decoded_string",txt,src,2))
    for ev in a.get("evidence",[]):
        txt=" ".join([str(ev.get("locator") or ""),str(ev.get("excerpt") or "")])
        sources.append(("evidence",txt,ev.get("id"),1))

    scores=defaultdict(int)
    members=defaultdict(set)
    excerpts=defaultdict(list)

    for stype,text,member,weight in sources:
        low=norm(text)
        if not low: continue
        for role,keywords in ROLES.items():
            hits=[k for k in keywords if k in low]
            if not hits: continue
            bonus=min(len(hits),4)
            scores[role]+=weight*bonus
            if member:
                members[role].add(str(member))
            if len(excerpts[role])<20:
                excerpts[role].append((stype,text[:260],member))

    # Decoder routines are particularly relevant to auth/data/stream if crypto/string building appears.
    for r in routines[:500]:
        hints=" ".join(r.get("hints") or [])
        f=norm((r.get("file") or "")+" "+(r.get("method") or "")+" "+hints)
        for role in ("authentication","data_source","stream_resolution"):
            if any(k in f for k in ROLES[role]):
                scores[role]+=2
                members[role].add(str(r.get("file") or ""))

    components=[]
    for role in ROLES:
        score=scores.get(role,0)
        if score<3:
            continue
        evrefs=[]
        for stype,text,member in excerpts[role][:12]:
            evrefs.append(add_evidence(a,"other",str(member or stype),text))
        cid="component."+role
        components.append({
            "id":cid,
            "name":DISPLAY[role],
            "role":role,
            "description":f"Clasificación funcional automática; score={score}.",
            "members":sorted(m for m in members[role] if m)[:300],
            "depends_on":[],
            "required_permissions":[],
            "external_services":[],
            "reuse_assessment":reuse(score,role),
            "evidence_refs":list(dict.fromkeys(evrefs)),
            "confidence":confidence(score)
        })

    # Replace only components generated by this role namespace, preserving future manual components.
    manual=[c for c in a.get("components",[]) if not str(c.get("id","")).startswith("component.")]
    a["components"]=manual+components

    summary={
        "ok":True,
        "project_id":args.project_id,
        "component_count":len(components),
        "components":[{
            "id":c["id"],
            "name":c["name"],
            "role":c["role"],
            "confidence":c["confidence"],
            "reuse_assessment":c["reuse_assessment"],
            "member_count":len(c["members"]),
            "evidence_count":len(c["evidence_refs"]),
            "score":scores[c["role"]]
        } for c in sorted(components,key=lambda c:(-scores[c["role"]],c["name"]))],
        "notes":[
            "V1 agrupa por evidencia textual y estructural.",
            "No declara todavía dependencias mínimas exportables.",
            "La siguiente capa calculará cierres de dependencias y paquetes reutilizables."
        ]
    }

    out=root/"work"/"functional"
    out.mkdir(parents=True,exist_ok=True)
    (out/"components.json").write_text(json.dumps(summary,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    notes=[n for n in a.get("notes",[]) if not str(n).startswith("FUNCTIONAL_COMPONENTIZER_V1_")]
    notes += [
        "FUNCTIONAL_COMPONENTIZER_V1_COMPLETE",
        f"FUNCTIONAL_COMPONENTIZER_V1_COMPONENTS={len(components)}"
    ]
    a["notes"]=notes
    analysis_path.write_text(json.dumps(a,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(summary,ensure_ascii=False))

if __name__=="__main__":
    main()
PY
chmod 755 "$ROOT/componentize_android.py"
python3 -m py_compile "$ROOT/componentize_android.py"
echo FUNCTIONAL_COMPONENTIZER_V1_SOURCE_OK

echo "=== 2. INTEGRATE INTO PIPELINE ==="
python3 - "$PIPE" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")
if 'COMPONENTIZER=Path("/home/ubuntu/Central/componentizer_v1/componentize_android.py")' not in s:
    s=s.replace(
        'DEOBF=Path("/home/ubuntu/Central/deobfuscator_v1/deobfuscate_android.py")\n',
        'DEOBF=Path("/home/ubuntu/Central/deobfuscator_v1/deobfuscate_android.py")\nCOMPONENTIZER=Path("/home/ubuntu/Central/componentizer_v1/componentize_android.py")\n',
        1
    )

old='''    stage(9,"Consolidando analysis.json y evidencia")
    stage(10,"Verificando salida final")

    overall_ok=(deobf_status!="FAILED")
'''
new='''    stage(9,"Agrupando funciones y consolidando analysis.json")
    componentization=None
    if deobf_status!="FAILED":
        rc_c,out_c,err_c=run(["python3",str(COMPONENTIZER),pid])
        if rc_c!=0:
            print(json.dumps({"ok":False,"stage":"componentization","project_id":pid,"stdout":out_c,"stderr":err_c},ensure_ascii=False),flush=True)
            raise SystemExit(rc_c or 2)
        componentization=parse_last_json(out_c)

    stage(10,"Verificando salida final")

    overall_ok=(deobf_status!="FAILED")
'''
if old not in s:
    raise SystemExit("PIPE_COMPONENTIZER_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

old='''        "deobfuscation":deobf,
        "analysis_path":str(PROJECTS/pid/"canon"/"analysis.json")
'''
new='''        "deobfuscation":deobf,
        "componentization":componentization,
        "analysis_path":str(PROJECTS/pid/"canon"/"analysis.json")
'''
if old not in s:
    raise SystemExit("PIPE_COMPONENTIZER_RESULT_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$PIPE"
echo FUNCTIONAL_COMPONENTIZER_PIPELINE_OK

echo "=== 3. ADD COMPONENT RESULTS ENDPOINT + UI CARD ==="
python3 - "$UI" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

# GET endpoint for component summary.
if '/components"' not in s:
    anchor='''        m=re.fullmatch(r"/api/runs/([A-Za-z0-9_-]+)/log",p)
'''
    insert='''        m=re.fullmatch(r"/api/runs/([A-Za-z0-9_-]+)/components",p)
        if m:
            r=get_run(m.group(1))
            if not r:return self.send_json(404,{"ok":False,"error":"RUN_NOT_FOUND"})
            pid=r.get("project_id")
            if not pid:return self.send_json(409,{"ok":False,"error":"PROJECT_NOT_READY"})
            fp=Path("/home/ubuntu/Central/projects")/pid/"work"/"functional"/"components.json"
            if not fp.is_file():return self.send_json(404,{"ok":False,"error":"COMPONENTS_NOT_READY"})
            try:return self.send_json(200,json.loads(fp.read_text(encoding="utf-8")))
            except Exception as e:return self.send_json(500,{"ok":False,"error":"COMPONENTS_READ_FAILED","detail":str(e)})

'''
    if anchor not in s:
        raise SystemExit("UI_COMPONENT_ENDPOINT_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert+anchor,1)

# Add card before log card.
if 'id="components"' not in s:
    anchor='''  <div class="card">
    <strong>Log en vivo</strong>
'''
    insert='''  <div class="card">
    <strong>Componentes detectados</strong>
    <div id="components" class="meta">Se mostrarán al terminar el análisis.</div>
  </div>

'''
    if anchor not in s:
        raise SystemExit("UI_COMPONENT_CARD_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert+anchor,1)

# Add renderer before watch().
if 'async function loadComponents(' not in s:
    anchor='''async function watch(){
'''
    func='''async function loadComponents(rid){
 const box=$('#components')
 if(!box)return
 try{
   const x=await api('api/runs/'+rid+'/components',{},3000)
   const cs=x.components||[]
   if(!cs.length){box.textContent='No se detectaron componentes funcionales con evidencia suficiente.';return}
   box.innerHTML=''
   for(const c of cs){
     const d=document.createElement('div');d.className='run'
     const l=document.createElement('div')
     l.innerHTML='<div><strong>'+c.name+'</strong></div><small>'+c.confidence+' · '+c.reuse_assessment+' · '+c.member_count+' miembros · '+c.evidence_count+' evidencias</small>'
     const b=document.createElement('span');b.className='badge';b.textContent=c.role
     d.append(l,b);box.appendChild(d)
   }
 }catch(e){
   box.textContent='Componentes todavía no disponibles.'
 }
}
'''
    if anchor not in s:
        raise SystemExit("UI_COMPONENT_RENDER_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,func+anchor,1)

# Load when completed and when selecting history run.
s=s.replace(
'''       break
     }
''',
'''       loadComponents(jid)
       break
     }
''',1) if 'loadComponents(jid)' not in s else s

# More reliable: active run completion uses run id, not project id.
old="""   if(r.status==='COMPLETED'||r.status==='ERROR'){$('#go').disabled=false;loadRuns();return}
"""
new="""   if(r.status==='COMPLETED'||r.status==='ERROR'){
     $('#go').disabled=false
     if(r.status==='COMPLETED')loadComponents(active)
     loadRuns();return
   }
"""
if old in s:
    s=s.replace(old,new,1)

# Clicking history should also load components.
old2="""   const b=document.createElement('button');b.className='badge';b.textContent=r.status||'—';b.onclick=()=>{active=r.id;watch()}
"""
new2="""   const b=document.createElement('button');b.className='badge';b.textContent=r.status||'—';b.onclick=()=>{active=r.id;watch();if(r.status==='COMPLETED')loadComponents(r.id)}
"""
if old2 in s:
    s=s.replace(old2,new2,1)

p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$UI"
echo FUNCTIONAL_COMPONENTS_UI_SOURCE_OK

echo "=== 4. TEST COMPONENTIZER ON LATEST SUCCESSFUL REAL PROJECT ==="
LATEST=$(python3 - <<'PY'
import json
from pathlib import Path
runs=Path("/home/ubuntu/Central/auditor_ui_v1/data/runs.json")
rows=json.load(open(runs,encoding="utf-8"))
for r in rows:
    if r.get("status")=="COMPLETED" and r.get("project_id"):
        print(r["project_id"]);break
PY
)
test -n "$LATEST"
echo "project=$LATEST"
OUT=$(sudo -u ubuntu python3 "$ROOT/componentize_android.py" "$LATEST")
echo "$OUT"
python3 /home/ubuntu/Central/canon/v1/validate_canon.py "/home/ubuntu/Central/projects/$LATEST/canon/analysis.json"
COUNT=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["component_count"])' <<<"$OUT")
test "$COUNT" -ge 1
echo FUNCTIONAL_COMPONENTIZER_REAL_PROJECT_OK
echo "component_count=$COUNT"

echo "=== 5. RESTART UI + PUBLIC CHECK ==="
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8792/api/health >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS --max-time 20 "https://cen-tral.duckdns.org/central/auditor/api/health" | grep -q '"ok": true'
curl -fsS --max-time 20 "https://cen-tral.duckdns.org/central/auditor/api/runs" >/tmp/componentizer-runs.json
echo FUNCTIONAL_COMPONENTS_PUBLIC_UI_OK

echo CENTRAL_FUNCTIONAL_COMPONENTIZER_V1_READY
echo "project_tested=$LATEST"
echo "backup=$BACKUP"
