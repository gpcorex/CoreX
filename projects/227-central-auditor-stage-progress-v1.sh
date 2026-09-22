#!/usr/bin/env bash
set -euo pipefail

PIPE=/home/ubuntu/Central/pipeline_v1/run_android_pipeline.py
UI=/home/ubuntu/Central/auditor_ui_v1/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/auditor-stage-progress-v1-$STAMP
mkdir -p "$BACKUP"
cp -a "$PIPE" "$BACKUP/run_android_pipeline.py.before"
cp -a "$UI" "$BACKUP/server.py.before"

echo "=== 1. PATCH PIPELINE WITH 10 NAMED STAGES ==="
python3 - "$PIPE" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

if "CENTRAL_STAGE_V1" not in s:
    s=s.replace(
        'def run(cmd):\n',
        '''# CENTRAL_STAGE_V1
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

def stage(n, detail=None):
    name=dict(STAGES)[n]
    print(json.dumps({
        "event":"stage",
        "stage":n,
        "stage_total":len(STAGES),
        "stage_name":name,
        "detail":detail
    },ensure_ascii=False),flush=True)

def run(cmd):
''',1)

    s=s.replace(
        '    src=Path(a.source).expanduser().resolve()\n',
        '    src=Path(a.source).expanduser().resolve()\n    stage(1,src.name)\n',1)

    s=s.replace(
        '    rc,out,err=run(cmd)\n    if rc!=0:\n',
        '    stage(2,"Registrando fuente y creando proyecto")\n    rc,out,err=run(cmd)\n    if rc!=0:\n',1)

    s=s.replace(
        '    ing=parse_last_json(out)\n    pid=ing["project_id"]\n\n    rc,out,err=run(["python3",str(AUDITOR),pid])\n',
        '''    ing=parse_last_json(out)
    pid=ing["project_id"]
    stage(3,"Leyendo identidad, paquete y versión")
    stage(4,"Analizando manifest, componentes y estructura")
    rc,out,err=run(["python3",str(AUDITOR),pid])
''',1)

    s=s.replace(
        '    audit=parse_last_json(out)\n\n    deobf=None\n',
        '''    audit=parse_last_json(out)
    stage(5,"Decodificación "+("completada" if audit.get("apktool_ok") else "no disponible"))
    stage(6,"Inventariando DEX, recursos, librerías y endpoints")

    deobf=None
''',1)

    s=s.replace(
        '    if audit.get("apktool_ok") and decoded.is_dir():\n',
        '''    if audit.get("apktool_ok") and decoded.is_dir():
        stage(7,"Buscando rutinas de decodificación/ofuscación")
        stage(8,"Procesando cadenas y resultados recuperables")
''',1)

    s=s.replace(
        '    result={\n',
        '''    stage(9,"Consolidando analysis.json y evidencia")
    stage(10,"Verificando salida final")
    result={
''',1)

p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$PIPE"
echo AUDITOR_PIPELINE_STAGES_PATCH_OK

echo "=== 2. PATCH AUDITOR UI TO SHOW STAGE N/10 ==="
python3 - "$UI" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

# Worker: capture structured stage events from pipeline stdout into run state.
old='''            for line in cp.stdout:
                log.write(line)
                line=line.strip()
                if line.startswith("{") and line.endswith("}"):
                    try:last_json=json.loads(line)
                    except Exception:pass
'''
new='''            for line in cp.stdout:
                log.write(line)
                line=line.strip()
                if line.startswith("{") and line.endswith("}"):
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
                        else:
                            last_json=evt
                    except Exception:
                        pass
'''
if old not in s:
    raise SystemExit("WORKER_STAGE_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

# Expose stage fields in runs list.
old='''                slim.append({k:r.get(k) for k in ("id","filename","kind","status","created_at","started_at","finished_at","project_id","size")})
'''
new='''                slim.append({k:r.get(k) for k in ("id","filename","kind","status","created_at","started_at","finished_at","project_id","size","stage","stage_total","stage_name","stage_detail")})
'''
if old not in s:
    raise SystemExit("RUN_LIST_STAGE_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

# Initial row gets stage 1.
old='''            "id":rid,"filename":filename,"kind":kind,"status":"QUEUED",
            "created_at":now(),"size":actual,"source_path":str(dest),"project_id":None
'''
new='''            "id":rid,"filename":filename,"kind":kind,"status":"QUEUED",
            "created_at":now(),"size":actual,"source_path":str(dest),"project_id":None,
            "stage":1,"stage_total":10,"stage_name":"Archivo recibido","stage_detail":"Archivo guardado en inbox"
'''
if old not in s:
    raise SystemExit("RUN_INIT_STAGE_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

# Add stage text in active status card.
old="""   $('#detail').textContent=r.filename+' · '+fmtBytes(r.size)+' · '+fmtTime(r.started_at||r.created_at)
   $('#project').textContent=r.project_id||'Esperando al pipeline…'
"""
new="""   const st=(r.stage&&r.stage_total)?('Etapa '+r.stage+'/'+r.stage_total+' · '+(r.stage_name||'')):''
   $('#detail').textContent=(st?st+'\n':'')+r.filename+' · '+fmtBytes(r.size)+' · '+fmtTime(r.started_at||r.created_at)+(r.stage_detail?'\n'+r.stage_detail:'')
   $('#detail').style.whiteSpace='pre-line'
   $('#project').textContent=r.project_id||'Esperando al pipeline…'
"""
if old not in s:
    raise SystemExit("ACTIVE_STAGE_UI_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

# Add stage text to history row.
old="""   const l=document.createElement('div');l.innerHTML='<div>'+r.filename+'</div><small>'+fmtTime(r.created_at)+(r.project_id?' · '+r.project_id:'')+'</small>'
"""
new="""   const l=document.createElement('div');const stageTxt=(r.stage&&r.stage_total)?(' · Etapa '+r.stage+'/'+r.stage_total+' · '+(r.stage_name||'')):''
   l.innerHTML='<div>'+r.filename+'</div><small>'+fmtTime(r.created_at)+(r.project_id?' · '+r.project_id:'')+stageTxt+'</small>'
"""
if old not in s:
    raise SystemExit("HISTORY_STAGE_UI_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$UI"
echo AUDITOR_UI_STAGE_DISPLAY_PATCH_OK

echo "=== 3. RESTART AUDITOR UI ==="
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8792/api/health >/tmp/auditor-stage-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/auditor-stage-health.json
echo
systemctl is-active central-auditor-ui.service
echo AUDITOR_UI_STAGE_SERVICE_OK

echo "=== 4. STATIC CONTRACT TEST ==="
grep -q 'Etapa ' "$UI"
grep -q '"event":"stage"' "$PIPE"
grep -q 'stage_total' "$PIPE"
echo AUDITOR_STAGE_CONTRACT_OK

echo "=== 5. PUBLIC UI CHECK ==="
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/ | grep -q 'Log en vivo'
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo AUDITOR_STAGE_PUBLIC_UI_OK

echo CENTRAL_AUDITOR_STAGE_PROGRESS_V1_READY
echo "backup=$BACKUP"
