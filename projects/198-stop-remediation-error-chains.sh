#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Interfaz/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/job-remediation-guard-$STAMP
mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. ADD REMEDIATION GUARD TABLE ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

anchor='''    c.execute("""CREATE TABLE IF NOT EXISTS message_attachments(
        message_id INTEGER NOT NULL,
        attachment_id TEXT NOT NULL,
        PRIMARY KEY(message_id,attachment_id)
    )""")
    c.commit()
'''
insert='''    c.execute("""CREATE TABLE IF NOT EXISTS message_attachments(
        message_id INTEGER NOT NULL,
        attachment_id TEXT NOT NULL,
        PRIMARY KEY(message_id,attachment_id)
    )""")
    c.execute("""CREATE TABLE IF NOT EXISTS job_remediations(
        parent_job_id TEXT PRIMARY KEY,
        child_job_id TEXT NOT NULL,
        created_at INTEGER NOT NULL
    )""")
    c.commit()
'''
if 'CREATE TABLE IF NOT EXISTS job_remediations' not in s:
    if anchor not in s:
        raise SystemExit("DB_SCHEMA_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert,1)

p.write_text(s,encoding="utf-8")
PY

echo "=== 2. MAKE DIAGNOSIS REPORT REMEDIATION ELIGIBILITY ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

old='''                diagnosis=diagnose_job_failure(job)
                return self.send_json(200,{
                    "ok":True,
                    "job_id":jid,
                    "error":job.get("error"),
                    "result":job.get("result"),
                    "diagnosis":diagnosis
                })
'''
new='''                diagnosis=diagnose_job_failure(job)
                c=db()
                own=c.execute("SELECT child_job_id FROM job_remediations WHERE parent_job_id=?",(jid,)).fetchone()
                parent=c.execute("SELECT parent_job_id FROM job_remediations WHERE child_job_id=?",(jid,)).fetchone()
                c.close()
                can_resolve=(own is None and parent is None)
                return self.send_json(200,{
                    "ok":True,
                    "job_id":jid,
                    "error":job.get("error"),
                    "result":job.get("result"),
                    "diagnosis":diagnosis,
                    "can_resolve":can_resolve,
                    "existing_remediation_job_id":own["child_job_id"] if own else None,
                    "is_remediation_job":bool(parent),
                    "parent_job_id":parent["parent_job_id"] if parent else None
                })
'''
if 'existing_remediation_job_id' not in s:
    if old not in s:
        raise SystemExit("DIAGNOSIS_RESPONSE_ANCHOR_NOT_FOUND")
    s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
PY

echo "=== 3. GUARD QUICK-FIX ENDPOINT: ONE ATTEMPT MAX ==="
python3 - <<'PY'
from pathlib import Path
import re
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

pat=r'''        if p=="/api/job-resolve":\n            try:\n.*?        if p=="/api/job-diagnose":'''
m=re.search(pat,s,flags=re.S)
if not m:
    raise SystemExit("JOB_RESOLVE_BLOCK_NOT_FOUND")

replacement='''        if p=="/api/job-resolve":
            try:
                b=self.read_json()
                jid=str(b.get("job_id") or "").strip()
                diagnosis=str(b.get("diagnosis") or "").strip()
                if not jid:
                    return self.send_json(400,{"ok":False,"error":"JOB_ID_REQUIRED"})

                c=db()
                parent=c.execute("SELECT parent_job_id FROM job_remediations WHERE child_job_id=?",(jid,)).fetchone()
                if parent:
                    c.close()
                    return self.send_json(409,{
                        "ok":False,
                        "error":"REMEDIATION_CHAIN_BLOCKED",
                        "detail":"Este trabajo ya es un intento de corrección. No se crearán correcciones encadenadas.",
                        "parent_job_id":parent["parent_job_id"]
                    })

                existing=c.execute("SELECT child_job_id FROM job_remediations WHERE parent_job_id=?",(jid,)).fetchone()
                if existing:
                    child=existing["child_job_id"]
                    c.close()
                    return self.send_json(200,{
                        "ok":True,
                        "reused":True,
                        "job_id":child,
                        "parent_job_id":jid
                    })
                c.close()

                out=http_json(CENTRAL+"/api/jobs/"+jid,timeout=12)
                failed=out.get("job") or out
                if str(failed.get("status") or "")!="ERROR":
                    return self.send_json(400,{"ok":False,"error":"JOB_NOT_IN_ERROR"})

                task=(
                    "INTENTO_UNICO_DE_REPARACION para el trabajo fallido "+jid+". "
                    "Verificá primero la causa real. Aplicá una sola corrección mínima y segura. "
                    "Probá el resultado. Si la corrección no resuelve el problema, terminá con ERROR "
                    "explicando la causa y no generes ni solicites otro trabajo de reparación. "
                    "No cambies arquitectura salvo necesidad demostrada. "
                    "Trabajo fallido: "+json.dumps(failed,ensure_ascii=False)[:12000]
                )
                if diagnosis:
                    task += " Diagnóstico previo: "+diagnosis[:6000]

                payload={
                    "task":task,
                    "source":"interfaz-remediation",
                    "project":"Central",
                    "conversation_id":str(b.get("conversation_id") or "")
                }
                created=http_json(CENTRAL+"/api/jobs","POST",payload,12)
                child=str(created.get("job_id") or "")
                if not child:
                    raise RuntimeError("REMEDIATION_JOB_ID_MISSING")

                c=db()
                c.execute("INSERT OR IGNORE INTO job_remediations(parent_job_id,child_job_id,created_at) VALUES(?,?,?)",
                          (jid,child,now()))
                c.commit(); c.close()

                return self.send_json(202,{
                    "ok":True,
                    "job_id":child,
                    "status":created.get("status","RECIBIDA"),
                    "parent_job_id":jid,
                    "one_shot":True
                })
            except Exception as e:
                return self.send_json(500,{"ok":False,"error":"JOB_RESOLVE_FAILED","detail":str(e)})
        if p=="/api/job-diagnose":'''

s=s[:m.start()]+replacement+s[m.end():]
p.write_text(s,encoding="utf-8")
PY

echo "=== 4. UI: NEVER OFFER RESOLVE ON A REMEDIATION FAILURE ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

old="""             const row=document.createElement('div');row.className='jobFixRow'
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
"""
new="""             const row=document.createElement('div');row.className='jobFixRow'
             const note=document.createElement('span');note.className='jobFixNote'
             if(dx.can_resolve){
               const fix=document.createElement('button');fix.className='jobFixBtn';fix.textContent='Resolver una vez'
               note.textContent='hace un único intento de corrección'
               fix.onclick=async()=>{
                 if(!confirm('¿Querés que Central haga un único intento de resolver este error?'))return
                 fix.disabled=true;fix.textContent='Resolviendo…'
                 try{
                   const fx=await api('api/job-resolve',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({job_id:jid,diagnosis:dx.diagnosis||'',conversation_id:cid||''})})
                   fix.textContent='Intento creado'
                   note.textContent=fx.job_id||''
                   if(fx.job_id)addJob(fx.job_id,fx.status||'RECIBIDA')
                 }catch(e){
                   fix.disabled=false;fix.textContent='Resolver una vez'
                   note.textContent='No se pudo iniciar la corrección: '+e.message
                 }
               }
               row.appendChild(fix)
             } else if(dx.is_remediation_job){
               note.textContent='La corrección también falló. Se detuvo la cadena automática. Revisá este diagnóstico antes de intentar otro cambio.'
             } else if(dx.existing_remediation_job_id){
               note.textContent='Ya existe un intento de corrección: '+dx.existing_remediation_job_id
             } else {
               note.textContent='No se habilita una nueva corrección automática para este error.'
             }
             row.appendChild(note);box.appendChild(row)
"""
if "Resolver una vez" not in s:
    if old not in s:
        raise SystemExit("QUICK_FIX_UI_ANCHOR_NOT_FOUND")
    s=s.replace(old,new,1)

s=s.replace("central-chat-pwa-v6","central-chat-pwa-v7")
p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo REMEDIATION_CHAIN_GUARD_SOURCE_OK

echo "=== 5. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/remediation-guard-health.json 2>/dev/null && break
  sleep 1
done
cat /tmp/remediation-guard-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_REMEDIATION_GUARD_SERVICE_OK

echo "=== 6. VERIFY PUBLIC UI ==="
PUB=$(curl -fsS --max-time 20 https://cen-tral.duckdns.org/interfaz/)
grep -q 'Resolver una vez' <<<"$PUB"
grep -q 'Se detuvo la cadena automática' <<<"$PUB"
grep -q 'api/job-resolve' <<<"$PUB"
echo REMEDIATION_CHAIN_GUARD_PUBLIC_OK

echo CENTRAL_JOB_REMEDIATION_GUARD_V1_READY
echo "backup=$BACKUP"
