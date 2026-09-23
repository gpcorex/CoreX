#!/usr/bin/env bash
set -euo pipefail

SCAFF=/home/ubuntu/Central/clean_adapter_scaffold_v1/build_clean_adapter_scaffold.py
MASTER=/home/ubuntu/Central/master_pipeline_v1/run_central_extraction.py
SERVER=/home/ubuntu/Central/auditor_ui_v1/server.py
PID=20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/auditor-xuper-empty-interface-fix-$STAMP
mkdir -p "$BACKUP"
cp -a "$SCAFF" "$BACKUP/scaffold.py.before"
cp -a "$MASTER" "$BACKUP/master.py.before"
cp -a "$SERVER" "$BACKUP/server.py.before"

echo "=== 1. MAKE EMPTY INTERFACE NON-FATAL ==="
python3 - "$SCAFF" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")
old='''    ops=iface.get("operations") or []
    if not ops:
        raise SystemExit("NO_INTERFACE_OPERATIONS")

    out=root/"work"/"component-packages"/args.role/"CLEAN_ADAPTER"
'''
new='''    ops=iface.get("operations") or []
    out=root/"work"/"component-packages"/args.role/"CLEAN_ADAPTER"
    if not ops:
        out.mkdir(parents=True,exist_ok=True)
        result={
          "ok":True,
          "skipped":True,
          "status":"NO_INTERFACE_OPERATIONS",
          "project_id":args.project_id,
          "role":args.role,
          "operation_count":0,
          "clean_adapter_path":str(out)
        }
        (out/"build-plan.json").write_text(
          json.dumps({
            "schema_version":"central.clean-adapter-plan.v1",
            "project_id":args.project_id,
            "role":args.role,
            "source_interface":str(iface_path),
            "operation_count":0,
            "implementation_status":"SKIPPED_NO_INTERFACE_OPERATIONS",
            "runtime_backend_required":False,
            "operations":[],
            "next_step":"No clean adapter generated because the behavior slice produced no interface operations."
          },ensure_ascii=False,indent=2)+chr(10),
          encoding="utf-8"
        )
        print(json.dumps(result,ensure_ascii=False))
        return

'''
if old not in s:
    raise SystemExit("SCAFFOLD_EMPTY_OPS_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)
p.write_text(s,encoding="utf-8")
PY

python3 - "$MASTER" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")
old='''        "scaffold_ok":bool(detail_scaffold and detail_scaffold.get("ok")),
      },'''
new='''        "scaffold_ok":bool(detail_scaffold and detail_scaffold.get("ok")),
        "scaffold_skipped":bool(detail_scaffold and detail_scaffold.get("skipped",False)),
        "scaffold_status":(detail_scaffold or {}).get("status"),
      },'''
if old not in s:
    raise SystemExit("MASTER_REPORT_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)
p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SCAFF" "$MASTER"
echo EMPTY_INTERFACE_NON_FATAL_SOURCE_OK

echo "=== 2. ADD FULL LOG API + COPY/DOWNLOAD CONTROLS ==="
python3 - "$SERVER" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

old='''        m=re.fullmatch(r"/api/runs/([A-Za-z0-9_-]+)/log",p)
        if m:
            rid=m.group(1); r=get_run(rid)
            if not r:return self.send_json(404,{"ok":False,"error":"RUN_NOT_FOUND"})
            lp=LOGS/f"{rid}.log"
            txt=lp.read_text(encoding="utf-8",errors="replace")[-200000:] if lp.is_file() else ""
            return self.send_bytes(200,txt,"text/plain; charset=utf-8")
'''
new='''        m=re.fullmatch(r"/api/runs/([A-Za-z0-9_-]+)/log/full",p)
        if m:
            rid=m.group(1); r=get_run(rid)
            if not r:return self.send_json(404,{"ok":False,"error":"RUN_NOT_FOUND"})
            lp=LOGS/f"{rid}.log"
            txt=lp.read_text(encoding="utf-8",errors="replace") if lp.is_file() else ""
            return self.send_bytes(200,txt,"text/plain; charset=utf-8")
        m=re.fullmatch(r"/api/runs/([A-Za-z0-9_-]+)/log",p)
        if m:
            rid=m.group(1); r=get_run(rid)
            if not r:return self.send_json(404,{"ok":False,"error":"RUN_NOT_FOUND"})
            lp=LOGS/f"{rid}.log"
            txt=lp.read_text(encoding="utf-8",errors="replace")[-200000:] if lp.is_file() else ""
            return self.send_bytes(200,txt,"text/plain; charset=utf-8")
'''
if old not in s:
    raise SystemExit("LOG_API_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

old='''  <div class="card">
    <strong>Log en vivo</strong>
    <pre id="log">Esperando un análisis…</pre>
  </div>
'''
new='''  <div class="card">
    <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap">
      <strong>Log en vivo</strong>
      <div style="display:flex;gap:8px">
        <button class="badge" id="copylog" type="button">Copiar todo</button>
        <button class="badge" id="downloadlog" type="button">Descargar log</button>
      </div>
    </div>
    <pre id="log">Esperando un análisis…</pre>
  </div>
'''
if old not in s:
    raise SystemExit("LOG_CARD_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

anchor='''$('#file').onchange=()=>{const f=$('#file').files[0];$('#go').disabled=!f;$('#filemeta').textContent=f?f.name+' · '+fmtBytes(f.size):'APK o XAPK'}
'''
insert='''async function fullLogText(){
 if(!active)throw new Error('Seleccioná un análisis')
 const r=await fetch('api/runs/'+active+'/log/full')
 if(!r.ok)throw new Error('No se pudo obtener el log completo')
 return await r.text()
}
$('#copylog').onclick=async()=>{
 try{
   const txt=await fullLogText()
   if(navigator.clipboard&&navigator.clipboard.writeText){
     await navigator.clipboard.writeText(txt)
   }else{
     const ta=document.createElement('textarea');ta.value=txt;document.body.appendChild(ta);ta.select();document.execCommand('copy');ta.remove()
   }
   $('#copylog').textContent='Copiado'
   setTimeout(()=>$('#copylog').textContent='Copiar todo',1500)
 }catch(e){alert(e.message)}
}
$('#downloadlog').onclick=async()=>{
 try{
   const txt=await fullLogText()
   const blob=new Blob([txt],{type:'text/plain;charset=utf-8'})
   const a=document.createElement('a')
   a.href=URL.createObjectURL(blob)
   a.download=(active||'auditor')+'.log'
   document.body.appendChild(a);a.click();a.remove()
   setTimeout(()=>URL.revokeObjectURL(a.href),1000)
 }catch(e){alert(e.message)}
}
$('#file').onchange=()=>{const f=$('#file').files[0];$('#go').disabled=!f;$('#filemeta').textContent=f?f.name+' · '+fmtBytes(f.size):'APK o XAPK'}
'''
if anchor not in s:
    raise SystemExit("JS_FILE_ANCHOR_NOT_FOUND")
s=s.replace(anchor,insert,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"

python3 - "$SERVER" >/tmp/auditor-patch-js.js <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text(encoding="utf-8")
m=re.search(r"INDEX=r'''(.*)'''\s*\n\s*if __name__",s,re.S)
if not m: raise SystemExit("INDEX_BLOCK_NOT_FOUND")
scripts=re.findall(r"<script>(.*?)</script>",m.group(1),re.S|re.I)
if not scripts: raise SystemExit("SCRIPT_BLOCK_NOT_FOUND")
print("\n".join(scripts))
PY
node --check /tmp/auditor-patch-js.js
echo AUDITOR_LOG_CONTROLS_SOURCE_OK

echo "=== 3. RESTART AUDITOR ==="
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8792/api/health >/dev/null 2>&1; then break; fi
  sleep 1
done
systemctl is-active central-auditor-ui.service
curl -fsS --max-time 10 http://127.0.0.1:8792/ >/tmp/auditor-patched.html
grep -q 'Copiar todo' /tmp/auditor-patched.html
grep -q 'Descargar log' /tmp/auditor-patched.html
grep -q '/log/full' "$SERVER"
echo AUDITOR_UI_PATCH_LOCAL_OK

echo "=== 4. RETEST FAILED XUPER PROJECT FROM STAGE 11 ==="
TMP=/tmp/xuper-master-retest-$STAMP.log
set +e
sudo -u ubuntu python3 "$MASTER" --project-id "$PID" >"$TMP" 2>&1
RC=$?
set -e
cat "$TMP"
test "$RC" -eq 0
grep -q '"stage": 16' "$TMP"
LAST=$(tail -n1 "$TMP")
python3 - "$LAST" <<'PY'
import json,sys,os
x=json.loads(sys.argv[1])
assert x.get("ok") is True
ds=x.get("master",{}).get("detail_specialization",{})
assert ds.get("scaffold_ok") is True
assert ds.get("scaffold_skipped") is True
assert ds.get("scaffold_status")=="NO_INTERFACE_OPERATIONS"
assert os.path.isfile(x["master_report"])
print("XUPER_MASTER_RETEST_OK")
print("project_id="+x["project_id"])
print("scaffold_status="+str(ds.get("scaffold_status")))
PY

echo "=== 5. PUBLISH RESULT ==="
OUT=/var/lib/conector/auditor-xuper-fix-result.txt
{
  echo "AUDITOR_XUPER_FIX_V1_OK"
  echo "generated_at=$(date -Is)"
  echo "project_id=$PID"
  echo "backup=$BACKUP"
  echo "service=$(systemctl is-active central-auditor-ui.service)"
  echo "copy_full_log=enabled"
  echo "download_full_log=enabled"
  echo "empty_interface=non_fatal"
  echo
  tail -n 12 "$TMP"
} >"$OUT"
/usr/local/sbin/conector-publish-result "$OUT" "vm-results/auditor-xuper-fix-result.txt" || true

echo AUDITOR_XUPER_EMPTY_INTERFACE_FIX_READY
