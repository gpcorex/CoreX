#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Interfaz/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/jobdiag-hard-repair-$STAMP
mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. HARD REPAIR MALFORMED HELPER ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
lines=p.read_text(encoding="utf-8").splitlines()

start=next((i for i,x in enumerate(lines) if x.startswith("def diagnose_job_failure(job):")),None)
end=next((i for i,x in enumerate(lines) if start is not None and i>start and x.startswith("class H(BaseHTTPRequestHandler):")),None)

if start is None or end is None:
    raise SystemExit(f"DIAGNOSIS_BLOCK_NOT_FOUND start={start} end={end}")

replacement=[
'def diagnose_job_failure(job):',
'    sep=chr(10)',
'    prompt=(',
'        "Analizá este trabajo fallido de Central. Explicá la causa concreta en lenguaje claro, "',
'        "y proponé la solución más directa y segura. No inventes datos que no estén en el job. "',
'        "Si falta información, decí exactamente qué falta. No ejecutes cambios."',
'        +sep+sep+"JOB FALLIDO:"+sep+json.dumps(job,ensure_ascii=False)[:14000]',
'    )',
'    payload={"messages":[{"role":"user","content":prompt}]}',
'    env=dict(os.environ)',
'    env["PYTHONPATH"]="/home/ubuntu/Central/native_v1"',
'    cp=subprocess.run(',
'        ["/usr/bin/python3","/home/ubuntu/Central/native_v1/native_chat.py"],',
'        input=json.dumps(payload,ensure_ascii=False),',
'        text=True,capture_output=True,timeout=120,env=env',
'    )',
'    if cp.returncode!=0:',
'        raise RuntimeError("JOB_DIAGNOSIS_FAILED:"+(cp.stderr or cp.stdout)[-800:])',
'    out=json.loads(cp.stdout)',
'    if not out.get("ok"):',
'        raise RuntimeError(str(out.get("error") or "JOB_DIAGNOSIS_FAILED"))',
'    return str(out.get("answer") or "").strip()',
'',
'class H(BaseHTTPRequestHandler):'
]

new_lines=lines[:start]+replacement+lines[end+1:]
p.write_text("\n".join(new_lines)+"\n",encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo JOB_DIAGNOSIS_HARD_SYNTAX_REPAIR_OK

echo "=== 2. ENSURE ENDPOINT EXISTS ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

if 'JOB_NOT_IN_ERROR' not in s:
    anchor='''        if p=="/api/message":
            try:
'''
    insert='''        if p=="/api/job-diagnose":
            try:
                b=self.read_json()
                jid=str(b.get("job_id") or "").strip()
                if not jid:
                    return self.send_json(400,{"ok":False,"error":"JOB_ID_REQUIRED"})
                out=http_json(CENTRAL+"/api/jobs/"+jid,timeout=12)
                job=out.get("job") or out
                if str(job.get("status") or "")!="ERROR":
                    return self.send_json(400,{"ok":False,"error":"JOB_NOT_IN_ERROR"})
                diagnosis=diagnose_job_failure(job)
                return self.send_json(200,{"ok":True,"job_id":jid,"error":job.get("error"),"result":job.get("result"),"diagnosis":diagnosis})
            except Exception as e:
                return self.send_json(500,{"ok":False,"error":"JOB_DIAGNOSIS_FAILED","detail":str(e)})
        if p=="/api/message":
            try:
'''
    if anchor not in s:
        raise SystemExit("MESSAGE_POST_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert,1)

p.write_text(s,encoding="utf-8")
PY

echo "=== 3. ENSURE ERROR UI EXISTS ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

if '.jobErrorDetail{' not in s:
    anchor='.job .meta{font-size:12px;color:var(--muted)}'
    if anchor not in s: raise SystemExit("JOB_META_CSS_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,anchor+'.jobErrorDetail{margin-top:10px;padding:10px;border-radius:10px;background:#23191b;border:1px solid #573238;white-space:pre-wrap;font-size:13px}.jobDiagnosis{margin-top:10px;padding:10px;border-radius:10px;background:var(--panel2);border:1px solid var(--line);white-space:pre-wrap;font-size:13px;line-height:1.45}.jobDiagTitle{font-weight:700;margin-bottom:6px}.jobDiagWait{color:var(--muted);font-size:12px;margin-top:8px}',1)

if 'Analizando causa y buscando una solución' not in s:
    old="""       if(el){
         let txt=''
         if(j.status==='COMPLETADA'){
           if(j.result&&j.result.message) txt=j.result.message
           else if(typeof j.result==='string') txt=j.result
           else txt='Trabajo completado y verificado.'
         } else txt='El trabajo terminó con error'+(j.error?': '+j.error:'')
         const r=document.createElement('div');r.style.marginTop='10px';r.textContent=txt;el.appendChild(r)
       }
       break
"""
    new="""       if(el){
         if(j.status==='COMPLETADA'){
           let txt=''
           if(j.result&&j.result.message) txt=j.result.message
           else if(typeof j.result==='string') txt=j.result
           else txt='Trabajo completado y verificado.'
           const r=document.createElement('div');r.style.marginTop='10px';r.textContent=txt;el.appendChild(r)
         } else {
           const detail=document.createElement('div');detail.className='jobErrorDetail'
           let rawError=j.error||''
           if(!rawError&&j.result){
             try{const n=j.result.native||j.result;rawError=n.error||n.detail||n.message||''}catch(e){}
           }
           detail.textContent=rawError?('Error real: '+rawError):'El trabajo terminó con error, pero Central Jobs no devolvió un detalle explícito.'
           el.appendChild(detail)
           const wait=document.createElement('div');wait.className='jobDiagWait';wait.textContent='Analizando causa y buscando una solución…';el.appendChild(wait)
           try{
             const dx=await api('api/job-diagnose',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({job_id:jid})})
             wait.remove()
             const box=document.createElement('div');box.className='jobDiagnosis'
             box.innerHTML='<div class="jobDiagTitle">Diagnóstico y solución sugerida</div>'+esc(dx.diagnosis||'No se pudo generar un diagnóstico.')
             el.appendChild(box)
           }catch(e){wait.textContent='No se pudo generar el diagnóstico automático: '+e.message}
         }
       }
       break
"""
    if old not in s:
        raise SystemExit("POLL_JOB_BLOCK_NOT_FOUND")
    s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo JOB_DIAGNOSIS_FULL_SOURCE_OK

echo "=== 4. VERIFY COMPONENTS ==="
for marker in 'def diagnose_job_failure' 'JOB_NOT_IN_ERROR' 'jobErrorDetail' 'Diagnóstico y solución sugerida' 'api/job-diagnose'; do
  grep -q "$marker" "$SERVER" || { echo "MISSING_MARKER=$marker"; exit 1; }
done
echo JOB_DIAGNOSIS_COMPONENTS_PRESENT_OK

echo "=== 5. RESTART + HEALTH ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/jobdiag196-health.json 2>/dev/null && break
  sleep 1
done
cat /tmp/jobdiag196-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_JOB_DIAGNOSIS_SERVICE_OK

echo "=== 6. PUBLIC UI ==="
PUB=$(curl -fsS --max-time 20 https://cen-tral.duckdns.org/interfaz/)
grep -q 'jobErrorDetail' <<<"$PUB"
grep -q 'Diagnóstico y solución sugerida' <<<"$PUB"
grep -q 'api/job-diagnose' <<<"$PUB"
echo JOB_ERROR_DIAGNOSIS_PUBLIC_UI_OK

echo CENTRAL_JOB_ERROR_DIAGNOSIS_V2_READY
echo "backup=$BACKUP"
