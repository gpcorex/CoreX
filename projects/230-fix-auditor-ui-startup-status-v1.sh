#!/usr/bin/env bash
set -euo pipefail

UI=/home/ubuntu/Central/auditor_ui_v1/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/auditor-ui-startup-status-v1-$STAMP
mkdir -p "$BACKUP"
cp -a "$UI" "$BACKUP/server.py.before"

echo "=== 1. PATCH AUDITOR UI STARTUP STATUS ==="
python3 - "$UI" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

old='''async function api(u,o){const r=await fetch(u,o);let j;try{j=await r.json()}catch{j={}}if(!r.ok)throw new Error(j.error||r.status);return j}
async function health(){try{await api('api/health');$('#health').textContent='online';$('#health').className='badge ok'}catch{$('#health').textContent='offline';$('#health').className='badge err'}}
'''
new='''async function fetchTimed(url,opt={},timeoutMs=2500){
 const c=new AbortController()
 const t=setTimeout(()=>c.abort(),timeoutMs)
 try{return await fetch(url,{...opt,signal:c.signal})}
 finally{clearTimeout(t)}
}
async function api(u,o,timeoutMs=2500){
 const r=await fetchTimed(u,o||{},timeoutMs)
 let j
 try{j=await r.json()}catch{j={}}
 if(!r.ok)throw new Error(j.error||r.status)
 return j
}
async function health(){
 $('#health').textContent='comprobando…';$('#health').className='badge'
 try{
   await api('api/health',{},2000)
   $('#health').textContent='online';$('#health').className='badge ok'
 }catch{
   $('#health').textContent='sin conexión';$('#health').className='badge err'
   setTimeout(health,5000)
 }
}
'''
if old not in s:
    raise SystemExit("HEALTH_API_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

old='''async function loadRuns(){
 try{
  const x=await api('api/runs');const box=$('#runs');box.innerHTML=''
  if(!x.runs.length){box.textContent='Todavía no hay análisis.';return}
'''
new='''async function loadRuns(){
 const box=$('#runs')
 box.textContent='Cargando…'
 try{
  const x=await api('api/runs',{},2500);box.innerHTML=''
  if(!x.runs.length){box.textContent='Todavía no hay análisis.';return}
'''
if old not in s:
    raise SystemExit("LOAD_RUNS_START_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

old=''' }catch(e){$('#runs').textContent='Error: '+e.message}
}
health();loadRuns()
'''
new=''' }catch(e){
   box.textContent='No se pudo cargar el historial.'
   setTimeout(loadRuns,5000)
 }
}
health()
loadRuns()
'''
if old not in s:
    raise SystemExit("LOAD_RUNS_END_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

# Avoid stale caching for the frontend after service restart.
if 'self.send_header("Cache-Control","no-store")' not in s:
    pass

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$UI"
echo AUDITOR_UI_STARTUP_STATUS_SOURCE_OK

echo "=== 2. RESTART AUDITOR UI ==="
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8792/api/health >/tmp/auditor-startup-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/auditor-startup-health.json
echo
systemctl is-active central-auditor-ui.service
echo AUDITOR_UI_STARTUP_STATUS_SERVICE_OK

echo "=== 3. VERIFY HTML CONTRACT ==="
HTML=$(curl -fsS --max-time 10 http://127.0.0.1:8792/)
grep -q 'fetchTimed' <<<"$HTML"
grep -q "2000" <<<"$HTML"
grep -q 'sin conexión' <<<"$HTML"
grep -q 'No se pudo cargar el historial.' <<<"$HTML"
echo AUDITOR_UI_STARTUP_STATUS_CONTRACT_OK

echo "=== 4. VERIFY PUBLIC UI ==="
PUB=$(curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/)
grep -q 'fetchTimed' <<<"$PUB"
curl -fsS --max-time 5 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo AUDITOR_UI_STARTUP_STATUS_PUBLIC_OK

echo CENTRAL_AUDITOR_UI_STARTUP_STATUS_V1_READY
echo "backup=$BACKUP"
