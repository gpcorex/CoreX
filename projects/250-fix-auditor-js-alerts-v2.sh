#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Central/auditor_ui_v1/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/auditor-js-alert-fix-v2-$STAMP
mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py.before"

echo "=== 1. REPAIR BROKEN ALERT JAVASCRIPT ==="
python3 - "$SERVER" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

# Replace the two alert helper functions wholesale so literal newlines
# can never break the embedded JavaScript again.
pat_bundle=r'''async function loadBundle\(rid,role\)\{.*?\n\}'''
rep_bundle='''async function loadBundle(rid,role){
 try{
   const x=await api('api/runs/'+rid+'/bundle/'+role,{},4000)
   const c=x.counts||{}
   const lines=[
     (x.name||role),
     'CORE '+(c.core||0),
     'Compartidas '+(c.shared||0),
     'Externas '+(c.external||0),
     'Framework '+(c.framework||0),
     'Recursos '+(c.resources||0),
     'APIs '+(c.apis||0)
   ]
   alert(lines.join(String.fromCharCode(10)))
 }catch(e){alert('Bundle todavía no disponible para '+role)}
}'''
s,n1=re.subn(pat_bundle,rep_bundle,s,count=1,flags=re.S)

pat_contract=r'''async function loadContract\(rid,role\)\{.*?\n\}'''
rep_contract='''async function loadContract(rid,role){
 try{
   const x=await api('api/runs/'+rid+'/contract/'+role,{},4000)
   const sm=x.summary||{},n=x.network||{}
   const ps=(x.permissions||[]).filter(p=>p.status==='supported_by_core').map(p=>p.permission)
   const lines=[
     (x.name||role),
     'Entradas '+(sm.observed_input_type_count||0),
     'Salidas '+(sm.observed_output_type_count||0),
     'Llamadas externas '+(sm.external_call_count||0),
     'Red '+(n.uses_network_indicators?'sí':'no'),
     'Permisos observados '+ps.length
   ].concat(ps)
   alert(lines.join(String.fromCharCode(10)))
 }catch(e){alert('Contrato todavía no disponible para '+role)}
}'''
s,n2=re.subn(pat_contract,rep_contract,s,count=1,flags=re.S)

if n1==0 and 'async function loadBundle' in s:
    raise SystemExit("LOAD_BUNDLE_REPAIR_FAILED")
if n2==0 and 'async function loadContract' in s:
    raise SystemExit("LOAD_CONTRACT_REPAIR_FAILED")

p.write_text(s,encoding="utf-8")
print(f"bundle_replaced={n1}")
print(f"contract_replaced={n2}")
PY

python3 -m py_compile "$SERVER"
echo AUDITOR_JS_ALERT_FIX_SOURCE_OK

echo "=== 2. EXTRACT + CHECK BROWSER JAVASCRIPT ==="
python3 - "$SERVER" >/tmp/auditor-js-alert-fix.js <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text(encoding="utf-8")
m=re.search(r"INDEX=r'''(.*)'''\s*\n\s*if __name__",s,re.S)
if not m: raise SystemExit("INDEX_BLOCK_NOT_FOUND")
scripts=re.findall(r"<script>(.*?)</script>",m.group(1),re.S|re.I)
if not scripts: raise SystemExit("SCRIPT_BLOCK_NOT_FOUND")
print("\n".join(scripts))
PY
node --check /tmp/auditor-js-alert-fix.js
echo AUDITOR_JS_ALERT_FIX_SYNTAX_OK

echo "=== 3. RESTART AUDITOR ==="
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8792/api/health >/dev/null 2>&1; then break; fi
  sleep 1
done
systemctl is-active central-auditor-ui.service
echo AUDITOR_JS_ALERT_FIX_SERVICE_OK

echo "=== 4. VERIFY PUBLIC JAVASCRIPT ==="
curl -fsS --max-time 20 "https://cen-tral.duckdns.org/central/auditor/?v=$STAMP" >/tmp/auditor-js-alert-public.html
python3 - <<'PY'
import re
h=open("/tmp/auditor-js-alert-public.html",encoding="utf-8").read()
scripts=re.findall(r"<script>(.*?)</script>",h,re.S|re.I)
assert scripts,"NO_PUBLIC_SCRIPT"
open("/tmp/auditor-js-alert-public.js","w",encoding="utf-8").write("\n".join(scripts))
PY
node --check /tmp/auditor-js-alert-public.js
echo AUDITOR_JS_ALERT_FIX_PUBLIC_OK

echo CENTRAL_AUDITOR_JS_ALERT_FIX_V2_READY
echo "fresh_url=https://cen-tral.duckdns.org/central/auditor/?v=$STAMP"
echo "backup=$BACKUP"
