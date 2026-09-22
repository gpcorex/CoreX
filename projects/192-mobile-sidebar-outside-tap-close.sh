#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Interfaz/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/mobile-sidebar-overlay-$STAMP
mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. ADD MOBILE SIDEBAR OVERLAY ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

# CSS overlay.
css_anchor='''.mobileHead{display:none}
@media(max-width:760px){
 .app{display:block}.side{position:fixed;z-index:5;inset:0 22% 0 0;transform:translateX(-105%);transition:.2s;box-shadow:20px 0 50px #0008}
 .side.open{transform:translateX(0)}.main{height:100%}.composerWrap{left:0}
 .mobileHead{display:inline-block;margin-right:12px;background:none;border:0;color:var(--text);font-size:22px}
 .top{padding-left:10px}.messages{padding-left:14px;padding-right:14px}.msg.user{max-width:90%}
}
'''

css_new='''.mobileHead{display:none}.sideOverlay{display:none}
@media(max-width:760px){
 .app{display:block}.side{position:fixed;z-index:6;inset:0 22% 0 0;transform:translateX(-105%);transition:.2s;box-shadow:20px 0 50px #0008}
 .side.open{transform:translateX(0)}
 .sideOverlay{display:block;position:fixed;z-index:5;inset:0;background:#0007;opacity:0;pointer-events:none;transition:.2s}
 .sideOverlay.open{opacity:1;pointer-events:auto}
 .main{height:100%}.composerWrap{left:0}
 .mobileHead{display:inline-block;margin-right:12px;background:none;border:0;color:var(--text);font-size:22px}
 .top{padding-left:10px}.messages{padding-left:14px;padding-right:14px}.msg.user{max-width:90%}
}
'''

if '.sideOverlay{' not in s:
    if css_anchor not in s:
        raise SystemExit("MOBILE_CSS_ANCHOR_NOT_FOUND")
    s=s.replace(css_anchor,css_new,1)

# HTML overlay between aside and main.
html_anchor='''</aside>
<main class="main">'''
html_new='''</aside>
<div class="sideOverlay" id="sideOverlay"></div>
<main class="main">'''
if 'id="sideOverlay"' not in s:
    if html_anchor not in s:
        raise SystemExit("OVERLAY_HTML_ANCHOR_NOT_FOUND")
    s=s.replace(html_anchor,html_new,1)

# JS helpers.
js_anchor='''async function openConv(id){
 cid=id; $('#side').classList.remove('open')
'''
js_new='''function closeSidebar(){
 $('#side').classList.remove('open');
 $('#sideOverlay').classList.remove('open');
}
function openSidebar(){
 $('#side').classList.add('open');
 $('#sideOverlay').classList.add('open');
}
async function openConv(id){
 cid=id; closeSidebar()
'''
if 'function closeSidebar()' not in s:
    if js_anchor not in s:
        raise SystemExit("SIDEBAR_JS_ANCHOR_NOT_FOUND")
    s=s.replace(js_anchor,js_new,1)

# Replace menu click.
old="""$('#send').onclick=send;$('#newBtn').onclick=()=>{if(selectionMode)leaveSelectionMode();newConv()};$('#menu').onclick=()=>$('#side').classList.toggle('open')
$('#selCancel').onclick=leaveSelectionMode;$('#selDelete').onclick=deleteSelectedConversations
"""
new="""$('#send').onclick=send;$('#newBtn').onclick=()=>{if(selectionMode)leaveSelectionMode();newConv()};$('#menu').onclick=()=>{if($('#side').classList.contains('open'))closeSidebar();else openSidebar()}
$('#sideOverlay').onclick=closeSidebar
$('#selCancel').onclick=leaveSelectionMode;$('#selDelete').onclick=deleteSelectedConversations
"""
if "$('#sideOverlay').onclick=closeSidebar" not in s:
    if old not in s:
        raise SystemExit("MENU_HANDLER_ANCHOR_NOT_FOUND")
    s=s.replace(old,new,1)

# Optional Escape key support.
esc_anchor="""$('#input').addEventListener('keydown',e=>{if(e.key==='Enter'&&(e.ctrlKey||e.metaKey)){e.preventDefault();send()}})
loadConvs()
"""
esc_new="""$('#input').addEventListener('keydown',e=>{if(e.key==='Enter'&&(e.ctrlKey||e.metaKey)){e.preventDefault();send()}})
document.addEventListener('keydown',e=>{if(e.key==='Escape')closeSidebar()})
loadConvs()
"""
if "if(e.key==='Escape')closeSidebar()" not in s:
    if esc_anchor not in s:
        raise SystemExit("ESC_HANDLER_ANCHOR_NOT_FOUND")
    s=s.replace(esc_anchor,esc_new,1)

s=s.replace("central-chat-pwa-v3","central-chat-pwa-v4")
p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo MOBILE_SIDEBAR_OVERLAY_PATCH_OK

echo "=== 2. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/sidebar-overlay-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/sidebar-overlay-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_SIDEBAR_OVERLAY_SERVICE_OK

echo "=== 3. PUBLIC UI MARKERS ==="
PUB=$(curl -fsS --max-time 20 https://cen-tral.duckdns.org/interfaz/)
grep -q 'id="sideOverlay"' <<<"$PUB"
grep -q 'function closeSidebar' <<<"$PUB"
grep -q "\$('#sideOverlay').onclick=closeSidebar" <<<"$PUB"
echo MOBILE_SIDEBAR_OUTSIDE_TAP_PUBLIC_OK

echo CENTRAL_MOBILE_SIDEBAR_OVERLAY_V1_READY
echo "backup=$BACKUP"
