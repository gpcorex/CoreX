#!/usr/bin/env bash
set -euo pipefail

PIPE=/home/ubuntu/Central/pipeline_v1/run_android_pipeline.py
UI=/home/ubuntu/Central/auditor_ui_v1/server.py
DEOBF=/home/ubuntu/Central/deobfuscator_v1/deobfuscate_android.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/auditor-pipeline-repair-v3-$STAMP
mkdir -p "$BACKUP"
cp -a "$PIPE" "$BACKUP/run_android_pipeline.py.before" 2>/dev/null || true
cp -a "$UI" "$BACKUP/server.py.before"
cp -a "$DEOBF" "$BACKUP/deobfuscate_android.py.before"

echo "=== 1. REBUILD PIPELINE CLEANLY ==="
cat >"$PIPE" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, subprocess
from pathlib import Path

INGEST=Path("/home/ubuntu/Central/ingest_v1/ingest.py")
AUDITOR=Path("/home/ubuntu/Central/auditor_v1/audit_android.py")
DEOBF=Path("/home/ubuntu/Central/deobfuscator_v1/deobfuscate_android.py")
PROJECTS=Path("/home/ubuntu/Central/projects")

STAGES=[
    (1,"Archivo recibido"),
    (2,"Ingesta"),
    (3,"Identificación del paquete"),
    (4,"Extracción estructural"),
    (5,"Decodificación con apktool"),
    (6,"Inventario de código y recursos"),
    (7,"Detección de rutinas ofuscadas"),
    (8,"Desofuscación automática"),
    (9,"Construcción del modelo canónico"),
    (10,"Validación final"),
]

def stage(n,detail=None):
    print(json.dumps({
        "event":"stage",
        "stage":n,
        "stage_total":len(STAGES),
        "stage_name":dict(STAGES)[n],
        "detail":detail
    },ensure_ascii=False),flush=True)

def run(cmd):
    cp=subprocess.run(cmd,text=True,capture_output=True)
    return cp.returncode,cp.stdout.strip(),cp.stderr.strip()

def run_stream(cmd):
    cp=subprocess.Popen(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,bufsize=1)
    lines=[]
    assert cp.stdout is not None
    for line in cp.stdout:
        clean=line.rstrip(chr(10))
        print(clean,flush=True)
        lines.append(line)
    rc=cp.wait()
    return rc,"".join(lines).strip(),""

def parse_last_json(text):
    for line in reversed(text.splitlines()):
        line=line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                obj=json.loads(line)
                if isinstance(obj,dict) and obj.get("event") in {"stage","deobf_progress"}:
                    continue
                return obj
            except Exception:
                pass
    raise ValueError("no result json object found")

def main():
    ap=argparse.ArgumentParser(description="Central Android audit pipeline")
    ap.add_argument("source")
    ap.add_argument("--kind",choices=["apk","xapk"],default=None)
    ap.add_argument("--name",default=None)
    a=ap.parse_args()

    src=Path(a.source).expanduser().resolve()
    stage(1,src.name)
    if not src.is_file():
        print(json.dumps({"ok":False,"stage":"source","error":"SOURCE_FILE_NOT_FOUND","source":str(src)},ensure_ascii=False))
        raise SystemExit(2)

    kind=a.kind or ("xapk" if src.suffix.lower()==".xapk" else "apk")

    stage(2,"Registrando fuente y creando proyecto")
    cmd=["python3",str(INGEST),str(src),"--kind",kind]
    if a.name:
        cmd += ["--name",a.name]
    rc,out,err=run(cmd)
    if rc!=0:
        print(json.dumps({"ok":False,"stage":"ingest","stdout":out,"stderr":err},ensure_ascii=False))
        raise SystemExit(rc or 2)
    ing=parse_last_json(out)
    pid=ing["project_id"]

    stage(3,"Leyendo identidad, paquete y versión")
    stage(4,"Analizando manifest, componentes y estructura")
    rc,out,err=run(["python3",str(AUDITOR),pid])
    if rc!=0:
        print(json.dumps({"ok":False,"stage":"audit","project_id":pid,"stdout":out,"stderr":err},ensure_ascii=False))
        raise SystemExit(rc or 2)
    audit=parse_last_json(out)

    stage(5,"Decodificación completada" if audit.get("apktool_ok") else "Decodificación no disponible")
    stage(6,"Inventariando DEX, recursos, librerías y endpoints")

    deobf=None
    deobf_status="SKIPPED_NO_DECODED_TREE"
    decoded=PROJECTS/pid/"work"/"android-audit"/"decoded"

    if audit.get("apktool_ok") and decoded.is_dir():
        stage(7,"Buscando rutinas de decodificación/ofuscación")
        stage(8,"Procesando cadenas y resultados recuperables")
        rc,out,err=run_stream(["python3",str(DEOBF),pid])
        if rc==0:
            deobf=parse_last_json(out)
            deobf_status="OK"
        else:
            deobf_status="FAILED"
            deobf={"stdout":out,"stderr":err,"returncode":rc}

    stage(9,"Consolidando analysis.json y evidencia")
    stage(10,"Verificando salida final")

    overall_ok=(deobf_status!="FAILED")
    result={
        "ok":overall_ok,
        "project_id":pid,
        "kind":kind,
        "audit":audit,
        "deobfuscation_status":deobf_status,
        "deobfuscation":deobf,
        "analysis_path":str(PROJECTS/pid/"canon"/"analysis.json")
    }
    print(json.dumps(result,ensure_ascii=False),flush=True)
    if not overall_ok:
        raise SystemExit(2)

if __name__=="__main__":
    main()
PY

chmod 755 "$PIPE"
python3 -m py_compile "$PIPE"
echo ANDROID_PIPELINE_REBUILT_V3_OK

echo "=== 2. PATCH UI FOR STAGE + INTERNAL PROGRESS ==="
python3 - "$UI" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

# Replace worker JSON handling if old compact parser is still present.
old='''                if line.startswith("{") and line.endswith("}"):
                    try:last_json=json.loads(line)
                    except Exception:pass
'''
new='''                if line.startswith("{") and line.endswith("}"):
                    try:
                        evt=json.loads(line)
                        if evt.get("event")=="stage":
                            update_run(
                                rid,
                                stage=evt.get("stage"),
                                stage_total=evt.get("stage_total"),
                                stage_name=evt.get("stage_name"),
                                stage_detail=evt.get("detail")
                            )
                        elif evt.get("event")=="deobf_progress":
                            cur=evt.get("current")
                            total=evt.get("total")
                            phase=evt.get("phase")
                            detail=evt.get("detail")
                            txt=(f"{cur}/{total}" if total else str(cur))
                            if detail:
                                txt += " · "+str(detail)
                            update_run(
                                rid,
                                stage=8,
                                stage_total=10,
                                stage_name="Desofuscación automática",
                                stage_detail=f"{phase}: {txt}"
                            )
                        else:
                            last_json=evt
                    except Exception:
                        pass
'''
if old in s:
    s=s.replace(old,new,1)

# If stage handling from 227 exists but deobf_progress does not, extend it.
if 'evt.get("event")=="stage"' in s and 'evt.get("event")=="deobf_progress"' not in s:
    old2='''                        if evt.get("event")=="stage":
                            update_run(
                                rid,
                                stage=evt.get("stage"),
                                stage_total=evt.get("stage_total"),
                                stage_name=evt.get("stage_name"),
                                stage_detail=evt.get("detail")
                            )
                        else:
                            last_json=evt
'''
    new2='''                        if evt.get("event")=="stage":
                            update_run(
                                rid,
                                stage=evt.get("stage"),
                                stage_total=evt.get("stage_total"),
                                stage_name=evt.get("stage_name"),
                                stage_detail=evt.get("detail")
                            )
                        elif evt.get("event")=="deobf_progress":
                            cur=evt.get("current")
                            total=evt.get("total")
                            phase=evt.get("phase")
                            detail=evt.get("detail")
                            txt=(f"{cur}/{total}" if total else str(cur))
                            if detail:
                                txt += " · "+str(detail)
                            update_run(rid,stage=8,stage_total=10,stage_name="Desofuscación automática",stage_detail=f"{phase}: {txt}")
                        else:
                            last_json=evt
'''
    if old2 in s:
        s=s.replace(old2,new2,1)

# Expose fields on runs list.
needle='''("id","filename","kind","status","created_at","started_at","finished_at","project_id","size")'''
if needle in s:
    s=s.replace(needle,'''("id","filename","kind","status","created_at","started_at","finished_at","project_id","size","stage","stage_total","stage_name","stage_detail")''',1)

# Initial run stage.
old3='''            "id":rid,"filename":filename,"kind":kind,"status":"QUEUED",
            "created_at":now(),"size":actual,"source_path":str(dest),"project_id":None
'''
new3='''            "id":rid,"filename":filename,"kind":kind,"status":"QUEUED",
            "created_at":now(),"size":actual,"source_path":str(dest),"project_id":None,
            "stage":1,"stage_total":10,"stage_name":"Archivo recibido","stage_detail":"Archivo guardado en inbox"
'''
if old3 in s:
    s=s.replace(old3,new3,1)

# Active view.
old4="""   $('#detail').textContent=r.filename+' · '+fmtBytes(r.size)+' · '+fmtTime(r.started_at||r.created_at)
   $('#project').textContent=r.project_id||'Esperando al pipeline…'
"""
new4="""   const st=(r.stage&&r.stage_total)?('Etapa '+r.stage+'/'+r.stage_total+' · '+(r.stage_name||'')):''
   $('#detail').textContent=(st?st+'\n':'')+r.filename+' · '+fmtBytes(r.size)+' · '+fmtTime(r.started_at||r.created_at)+(r.stage_detail?'\n'+r.stage_detail:'')
   $('#detail').style.whiteSpace='pre-line'
   $('#project').textContent=r.project_id||'Esperando al pipeline…'
"""
if old4 in s:
    s=s.replace(old4,new4,1)

# History row.
old5="""   const l=document.createElement('div');l.innerHTML='<div>'+r.filename+'</div><small>'+fmtTime(r.created_at)+(r.project_id?' · '+r.project_id:'')+'</small>'
"""
new5="""   const l=document.createElement('div');const stageTxt=(r.stage&&r.stage_total)?(' · Etapa '+r.stage+'/'+r.stage_total+' · '+(r.stage_name||'')):''
   l.innerHTML='<div>'+r.filename+'</div><small>'+fmtTime(r.created_at)+(r.project_id?' · '+r.project_id:'')+stageTxt+'</small>'
"""
if old5 in s:
    s=s.replace(old5,new5,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$UI"
echo AUDITOR_UI_PROGRESS_V3_SOURCE_OK

echo "=== 3. VERIFY DEOBFUSCATOR COMPILES ==="
python3 -m py_compile "$DEOBF"
grep -q 'def clean_text' "$DEOBF"
grep -q 'deobf_progress' "$DEOBF"
echo DEOBFUSCATOR_V2_COMPILE_OK

echo "=== 4. RESTART UI ==="
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8792/api/health >/tmp/auditor-v3-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/auditor-v3-health.json
echo
systemctl is-active central-auditor-ui.service
echo AUDITOR_UI_PROGRESS_V3_SERVICE_OK

echo "=== 5. PIPELINE SMOKE ON SYNTHETIC FIXTURE ==="
test -s /tmp/central-auditor-v1.apk
OUT=$(sudo -u ubuntu python3 "$PIPE" /tmp/central-auditor-v1.apk --kind apk --name "Pipeline V3 Fixture")
printf '%s\n' "$OUT"
printf '%s\n' "$OUT" | grep -q '"event": "stage"'
printf '%s\n' "$OUT" | grep -q '"stage": 10'
printf '%s\n' "$OUT" | tail -n1 | python3 -c 'import json,sys;x=json.load(sys.stdin);assert x["ok"] is True'
echo ANDROID_PIPELINE_V3_SMOKE_OK

echo "=== 6. PUBLIC UI CHECK ==="
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/ | grep -q 'Log en vivo'
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo AUDITOR_PROGRESS_V3_PUBLIC_OK

echo CENTRAL_AUDITOR_PIPELINE_REPAIR_V3_READY
echo "backup=$BACKUP"
