#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Interfaz/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/job-error-quick-fix-$STAMP
mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. ADD QUICK-FIX ENDPOINT ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

anchor='''        if p=="/api/job-diagnose":
            try:
'''
if '"/api/job-resolve"' not in s:
    insert='''        if p=="/api/job-resolve":
            try:
                b=self.read_json()
                jid=str(b.get("job_id") or "").strip()
                diagnosis=str(b.get("diagnosis") or "").strip()
                if not jid:
                    return self.send_json(400,{"ok":False,"error":"JOB_ID_REQUIRED"})
                out=http_json(CENTRAL+"/api/jobs/"+jid,timeout=12)
                failed=out.get("job") or out
                if str(failed.get("status") or "")!="ERROR":
                    return self.send_json(400,{"ok":False,"error":"JOB_NOT_IN_ERROR"})
                task=(
                    "Resolvé el error del trabajo fallido "+jid+". "
                    "Primero verificá la causa real con la información disponible. "
                    "Aplicá la corrección mínima y segura, probala y no marques el trabajo como completado "
                    "hasta verificar que el problema original quedó resuelto. "
                    "No inventes dependencias ni cambies arquitectura salvo que sea estrictamente necesario. "
                    "Trabajo fallido: "+json.dumps(failed,ensure_ascii=False)[:12000]
                )
                if diagnosis:
                    task += " Diagnóstico previo: "+diagnosis[:6000]
                payload={
                    "task":task,
                    "source":"interfaz",
                    "project":"Central",
                    "conversation_id":str(b.get("conversation_id") or "")
                }
                created=http_json(CENTRAL+"/api/jobs","POST",payload,12)
                return self.send_json(202,{
                    "ok":True,
                    "job_id":created.get("job_id"),
                    "status":created.get("status","RECIBIDA"),
                    "parent_job_id":jid
                })
            except Exception as e:
                return self.send_json(500,{"ok":False,"error":"JOB_RESOLVE_FAILED","detail":str(e)})
'''
    if anchor not in s:
        raise SystemExit("JOB_DIAGNOSE_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert+anchor,1)

p.write_text(s,encoding="utf-8")
PY

echo "=== 2. ADD QUICK-FIX BUTTON TO ERROR CARD ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

css_anchor='.jobDiagTitle{font-weight:700;margin-bottom:6px}.jobDiagWait{color:var(--muted);font-size:12px;margin-top:8px}'
css_new=css_anchor+'.jobFixRow{display:flex;gap:8px;margin-top:10px}.jobFixBtn{border:1px solid var(--line);background:var(--accent);color:#111;border-radius:10px;padding:8px 12px;font-weight:700}.jobFixBtn:disabled{opacity:.55}.jobFixNote{font-size:12px;color:var(--muted);align-self:center}'
if '.jobFixBtn{' not in s:
    if css_anchor not in s:
        raise SystemExit("JOB_DIAG_CSS_ANCHOR_NOT_FOUND")
    s=s.replace(css_anchor,css_new,1)

old="""             const box=document.createElement('div');box.className='jobDiagnosis'
             box.innerHTML='<div class="jobDiagTitle">Diagnóstico y solución sugerida</div>'+esc(dx.diagnosis||'No se pudo generar un diagnóstico.')
             el.appendChild(box)
"""
new="""             const box=document.createElement('div');box.className='jobDiagnosis'
             box.innerHTML='<div class="jobDiagTitle">Diagnóstico y solución sugerida</div>'+esc(dx.diagnosis||'No se pudo generar un diagnóstico.')
             const row=document.createElement('div');row.className='jobFixRow'
             const fix=document.createElement('button');fix.className='jobFixBtn';fix.textContent='Resolver'
             const note=document.createElement('span');note.className='jobFixNote';note.textContent='crea un trabajo nuevo con la corrección'
             fix.onclick=async()=>{
               if(!confirm('¿Querés que Central intente resolver este error ahora?'))return
               fix.disabled=true;fix.textContent='Resolviendo…'
               try{
                 const fx=await api('api/job-resolve',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({job_id:jid,diagnosis:dx.diagnosis||'',conversation_id:cid||''})})
                 fix.textContent='Trabajo creado'
                 note.textContent=fx.job_id||''
                 if(fx.job_id)addJob(fx.job_id,fx.status||'RECIBIDA')
               }catch(e){
                 fix.disabled=false;fix.textContent='Resolver'
                 note.textContent='No se pudo iniciar la corrección: '+e.message
               }
             }
             row.appendChild(fix);row.appendChild(note);box.appendChild(row)
             el.appendChild(box)
"""
if "fix.textContent='Resolver'" not in s:
    if old not in s:
        raise SystemExit("DIAGNOSIS_BOX_ANCHOR_NOT_FOUND")
    s=s.replace(old,new,1)

s=s.replace("central-chat-pwa-v5","central-chat-pwa-v6")
p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo JOB_QUICK_FIX_SOURCE_OK

echo "=== 3. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/jobfix-health.json 2>/dev/null && break
  sleep 1
done
cat /tmp/jobfix-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_JOB_QUICK_FIX_SERVICE_OK

echo "=== 4. PUBLIC UI MARKERS ==="
PUB=$(curl -fsS --max-time 20 https://cen-tral.duckdns.org/interfaz/)
grep -q 'jobFixBtn' <<<"$PUB"
grep -q "fix.textContent='Resolver'" <<<"$PUB"
grep -q 'api/job-resolve' <<<"$PUB"
echo JOB_QUICK_FIX_PUBLIC_UI_OK

echo CENTRAL_JOB_ERROR_QUICK_FIX_V1_READY
echo "backup=$BACKUP"
