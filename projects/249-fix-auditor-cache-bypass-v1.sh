#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Central/auditor_ui_v1/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/auditor-cache-bypass-v1-$STAMP
mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py.before"

echo "=== 1. VERIFY CURRENT AUDITOR HTML JAVASCRIPT ==="
curl -fsS --max-time 10 http://127.0.0.1:8792/ >/tmp/auditor-current.html
python3 - <<'PY'
import re
h=open("/tmp/auditor-current.html",encoding="utf-8").read()
scripts=re.findall(r"<script>(.*?)</script>",h,re.S|re.I)
assert scripts,"NO_SCRIPT_BLOCK"
open("/tmp/auditor-current.js","w",encoding="utf-8").write("\n".join(scripts))
print("AUDITOR_CURRENT_JS_EXTRACT_OK")
PY
node --check /tmp/auditor-current.js
echo AUDITOR_CURRENT_JS_SYNTAX_OK

echo "=== 2. ADD CACHE-BYPASS HEADERS + CLIENT VERSION MARKER ==="
python3 - "$SERVER" "$STAMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); stamp=sys.argv[2]
s=p.read_text(encoding="utf-8")

# Strong no-cache headers on every Auditor response.
old='''        self.send_header("Cache-Control","no-store")
        self.send_header("Content-Length",str(len(raw)))
'''
new='''        self.send_header("Cache-Control","no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma","no-cache")
        self.send_header("Expires","0")
        self.send_header("X-Auditor-Build","'''+stamp+'''")
        self.send_header("Content-Length",str(len(raw)))
'''
if old in s:
    s=s.replace(old,new,1)

# Add visible build marker and safe SW bypass for this page only.
marker="AUDITOR_CACHE_BYPASS_V1"
if marker not in s:
    anchor='''document.documentElement.dataset.auditorBoot='AUDITOR_UI_CLIENT_BOOT_V1'
'''
    insert='''document.documentElement.dataset.auditorBoot='AUDITOR_UI_CLIENT_BOOT_V1'
document.documentElement.dataset.auditorCache='AUDITOR_CACHE_BYPASS_V1'
if('serviceWorker' in navigator){
 navigator.serviceWorker.getRegistrations().then(rs=>{
   for(const r of rs){
     const scope=(r.scope||'')
     if(scope.includes('/central/auditor/')||scope.endsWith('/auditor/')) r.unregister()
   }
 }).catch(()=>{})
}
'''
    if anchor in s:
        s=s.replace(anchor,insert,1)
    else:
        # Fallback before health/loadRuns startup.
        anchor2='''health()
loadRuns()
'''
        if anchor2 not in s:
            raise SystemExit("AUDITOR_BOOT_ANCHOR_NOT_FOUND")
        s=s.replace(anchor2,'''document.documentElement.dataset.auditorCache='AUDITOR_CACHE_BYPASS_V1'
if('serviceWorker' in navigator){
 navigator.serviceWorker.getRegistrations().then(rs=>{
   for(const r of rs){
     const scope=(r.scope||'')
     if(scope.includes('/central/auditor/')||scope.endsWith('/auditor/')) r.unregister()
   }
 }).catch(()=>{})
}
health()
loadRuns()
''',1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo AUDITOR_CACHE_BYPASS_SOURCE_OK

echo "=== 3. RESTART AND VERIFY LOCAL + PUBLIC HTML ==="
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8792/api/health >/dev/null 2>&1; then break; fi
  sleep 1
done

curl -fsS --max-time 10 http://127.0.0.1:8792/ >/tmp/auditor-local-v1.html
grep -q 'AUDITOR_CACHE_BYPASS_V1' /tmp/auditor-local-v1.html
curl -fsSI --max-time 10 http://127.0.0.1:8792/ | grep -qi 'cache-control: no-store, no-cache, must-revalidate, max-age=0'
echo AUDITOR_CACHE_BYPASS_LOCAL_OK

curl -fsS --max-time 20 "https://cen-tral.duckdns.org/central/auditor/?v=$STAMP" >/tmp/auditor-public-v1.html
grep -q 'AUDITOR_CACHE_BYPASS_V1' /tmp/auditor-public-v1.html
python3 - <<'PY'
import re
h=open("/tmp/auditor-public-v1.html",encoding="utf-8").read()
scripts=re.findall(r"<script>(.*?)</script>",h,re.S|re.I)
assert scripts
open("/tmp/auditor-public-v1.js","w",encoding="utf-8").write("\n".join(scripts))
PY
node --check /tmp/auditor-public-v1.js
echo AUDITOR_CACHE_BYPASS_PUBLIC_JS_OK

echo CENTRAL_AUDITOR_CACHE_BYPASS_V1_READY
echo "fresh_url=https://cen-tral.duckdns.org/central/auditor/?v=$STAMP"
echo "backup=$BACKUP"
