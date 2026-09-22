#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Interfaz/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/conversation-multiselect-$STAMP
mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. ADD BULK CONVERSATION DELETE API ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

anchor='''    def log_message(self, fmt, *args):
        pass
'''

insert='''    def do_DELETE(self):
        p=urlparse(self.path).path
        if p=="/api/conversations":
            try:
                b=self.read_json()
                ids=[str(x) for x in (b.get("ids") or []) if str(x).startswith("CV-")]
                ids=list(dict.fromkeys(ids))[:100]
                if not ids:
                    return self.send_json(400,{"ok":False,"error":"CONVERSATION_IDS_REQUIRED"})

                c=db()
                deleted=[]
                files=[]
                for cid in ids:
                    row=c.execute("SELECT id FROM conversations WHERE id=?",(cid,)).fetchone()
                    if not row:
                        continue
                    ars=c.execute("SELECT id,path FROM attachments WHERE conversation_id=?",(cid,)).fetchall()
                    files.extend([str(a["path"]) for a in ars])
                    mids=c.execute("SELECT id FROM messages WHERE conversation_id=?",(cid,)).fetchall()
                    for mr in mids:
                        c.execute("DELETE FROM message_attachments WHERE message_id=?",(mr["id"],))
                    c.execute("DELETE FROM messages WHERE conversation_id=?",(cid,))
                    c.execute("DELETE FROM attachments WHERE conversation_id=?",(cid,))
                    c.execute("DELETE FROM conversations WHERE id=?",(cid,))
                    deleted.append(cid)
                c.commit()
                c.close()

                root=ATTACH_ROOT.resolve()
                for raw in files:
                    try:
                        fp=Path(raw).resolve()
                        if root in fp.parents and fp.is_file():
                            fp.unlink()
                            try:
                                fp.parent.rmdir()
                            except OSError:
                                pass
                    except Exception:
                        pass

                return self.send_json(200,{"ok":True,"deleted":deleted,"count":len(deleted)})
            except Exception as e:
                return self.send_json(500,{"ok":False,"error":"CONVERSATION_DELETE_FAILED","detail":str(e)})
        return self.send_json(404,{"ok":False,"error":"NOT_FOUND"})

    def log_message(self, fmt, *args):
        pass
'''

if 'CONVERSATION_DELETE_FAILED' not in s:
    if anchor not in s:
        raise SystemExit("DELETE_METHOD_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo CONVERSATION_BULK_DELETE_API_PATCH_OK

echo "=== 2. ADD LONG-PRESS MULTISELECT UI ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

# CSS
css_anchor='''.conv button:hover,.conv button.active{background:var(--panel2);color:var(--text)}'''
css_new='''.conv button:hover,.conv button.active{background:var(--panel2);color:var(--text)}
.conv button.selected{background:#2a3343;color:var(--text);outline:1px solid #78879b}
.selectionBar{display:none;align-items:center;gap:8px;margin-top:10px;padding:8px;border:1px solid var(--line);border-radius:12px;background:var(--panel)}
.selectionBar.show{display:flex}.selectionCount{flex:1;font-size:13px;color:var(--muted)}
.selAction{border:1px solid var(--line);background:var(--panel2);color:var(--text);border-radius:9px;padding:7px 10px}
.selDelete{border-color:#7a3434;color:#ffb3b3}
.conv button{-webkit-user-select:none;user-select:none;-webkit-touch-callout:none}'''
if '.selectionBar{' not in s:
    if css_anchor not in s:
        raise SystemExit("SELECTION_CSS_ANCHOR_NOT_FOUND")
    s=s.replace(css_anchor,css_new,1)

# HTML selection bar below new conversation button.
html_anchor=''' <button class="new" id="newBtn">＋ Nueva conversación</button>
 <div class="conv" id="conv"></div>'''
html_new=''' <button class="new" id="newBtn">＋ Nueva conversación</button>
 <div class="selectionBar" id="selectionBar">
   <span class="selectionCount" id="selectionCount">0 seleccionadas</span>
   <button class="selAction" id="selCancel">Cancelar</button>
   <button class="selAction selDelete" id="selDelete">Eliminar</button>
 </div>
 <div class="conv" id="conv"></div>'''
if 'id="selectionBar"' not in s:
    if html_anchor not in s:
        raise SystemExit("SELECTION_HTML_ANCHOR_NOT_FOUND")
    s=s.replace(html_anchor,html_new,1)

# State.
state_anchor='''let cid=null, polling=new Map(), pendingAttachments=[];'''
state_new='''let cid=null, polling=new Map(), pendingAttachments=[], selectionMode=false, selectedConversations=new Set();'''
if 'selectedConversations=new Set()' not in s:
    if state_anchor not in s:
        raise SystemExit("SELECTION_STATE_ANCHOR_NOT_FOUND")
    s=s.replace(state_anchor,state_new,1)

# Insert helpers before loadConvs.
load_anchor='''async function loadConvs(){
'''
helpers=r'''function updateSelectionBar(){
 const n=selectedConversations.size;
 $('#selectionBar')?.classList.toggle('show',selectionMode);
 if($('#selectionCount'))$('#selectionCount').textContent=n+' seleccionada'+(n===1?'':'s');
 if($('#selDelete'))$('#selDelete').disabled=n===0;
}
function leaveSelectionMode(){
 selectionMode=false;selectedConversations.clear();updateSelectionBar();loadConvs()
}
function toggleConversationSelection(id){
 selectionMode=true;
 if(selectedConversations.has(id))selectedConversations.delete(id);else selectedConversations.add(id);
 if(selectedConversations.size===0)selectionMode=false;
 updateSelectionBar();loadConvs()
}
async function deleteSelectedConversations(){
 const ids=[...selectedConversations];if(!ids.length)return;
 if(!confirm('¿Eliminar '+ids.length+' conversación'+(ids.length===1?'':'es')+'? Esta acción no se puede deshacer.'))return;
 try{
   const x=await api('api/conversations',{method:'DELETE',headers:{'Content-Type':'application/json'},body:JSON.stringify({ids})});
   if(cid&&ids.includes(cid)){cid=null;$('#title').textContent='Nueva conversación';$('#thread').innerHTML='<div class="empty">Escribí para empezar.</div>'}
   selectionMode=false;selectedConversations.clear();updateSelectionBar();await loadConvs();
 }catch(e){alert('No se pudieron eliminar las conversaciones: '+e.message)}
}
async function loadConvs(){
'''
if 'function toggleConversationSelection(' not in s:
    if load_anchor not in s:
        raise SystemExit("LOAD_CONVS_ANCHOR_NOT_FOUND")
    s=s.replace(load_anchor,helpers,1)

# Replace current conversation button creation line.
old_line="""  for(const c of x.conversations){const b=document.createElement('button');b.textContent=c.title;b.className=c.id===cid?'active':'';b.onclick=()=>openConv(c.id);box.appendChild(b)}
"""
new_line=r'''  for(const c of x.conversations){
   const b=document.createElement('button');b.textContent=c.title;
   b.className=[c.id===cid?'active':'',selectedConversations.has(c.id)?'selected':''].filter(Boolean).join(' ');
   let timer=null,longPressed=false;
   const start=()=>{longPressed=false;timer=setTimeout(()=>{longPressed=true;toggleConversationSelection(c.id)},550)};
   const cancel=()=>{if(timer){clearTimeout(timer);timer=null}};
   b.addEventListener('pointerdown',start);
   b.addEventListener('pointerup',cancel);
   b.addEventListener('pointercancel',cancel);
   b.addEventListener('pointerleave',cancel);
   b.addEventListener('contextmenu',e=>e.preventDefault());
   b.onclick=e=>{
     if(longPressed){longPressed=false;e.preventDefault();return}
     if(selectionMode){toggleConversationSelection(c.id);return}
     openConv(c.id)
   };
   box.appendChild(b)
  }
  updateSelectionBar()
'''
if 'longPressed=false' not in s:
    if old_line not in s:
        raise SystemExit("CONVERSATION_RENDER_ANCHOR_NOT_FOUND")
    s=s.replace(old_line,new_line,1)

# Button handlers.
click_anchor="""$('#send').onclick=send;$('#newBtn').onclick=newConv;$('#menu').onclick=()=>$('#side').classList.toggle('open')
"""
click_new="""$('#send').onclick=send;$('#newBtn').onclick=()=>{if(selectionMode)leaveSelectionMode();newConv()};$('#menu').onclick=()=>$('#side').classList.toggle('open')
$('#selCancel').onclick=leaveSelectionMode;$('#selDelete').onclick=deleteSelectedConversations
"""
if "$('#selDelete').onclick" not in s:
    if click_anchor not in s:
        raise SystemExit("SELECTION_BUTTON_HANDLER_ANCHOR_NOT_FOUND")
    s=s.replace(click_anchor,click_new,1)

# Bump known PWA cache name if present.
s=s.replace("central-chat-pwa-v2","central-chat-pwa-v3")

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo CONVERSATION_LONGPRESS_MULTISELECT_UI_PATCH_OK

echo "=== 3. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/conv-select-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/conv-select-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_CONVERSATION_SELECTION_SERVICE_OK

echo "=== 4. BULK DELETE API TEST WITH TEMP CONVERSATIONS ==="
C1=$(curl -fsS -H 'Content-Type: application/json' -d '{"title":"TEMP DELETE TEST 1"}' http://127.0.0.1:8791/api/conversations | python3 -c 'import json,sys;print(json.load(sys.stdin)["conversation_id"])')
C2=$(curl -fsS -H 'Content-Type: application/json' -d '{"title":"TEMP DELETE TEST 2"}' http://127.0.0.1:8791/api/conversations | python3 -c 'import json,sys;print(json.load(sys.stdin)["conversation_id"])')
REQ=/tmp/delete-conversations-test.json
python3 - "$C1" "$C2" "$REQ" <<'PY'
import json,sys
c1,c2,dst=sys.argv[1:]
json.dump({"ids":[c1,c2]},open(dst,"w"),separators=(",",":"))
PY
DEL=$(curl -fsS -X DELETE -H 'Content-Type: application/json' --data-binary @"$REQ" http://127.0.0.1:8791/api/conversations)
echo "$DEL"
DEL_JSON="$DEL" C1="$C1" C2="$C2" python3 - <<'PY'
import json,os
x=json.loads(os.environ["DEL_JSON"])
assert x["ok"] is True,x
assert x["count"]==2,x
assert set(x["deleted"])=={os.environ["C1"],os.environ["C2"]},x
print("CONVERSATION_BULK_DELETE_API_OK")
PY

echo "=== 5. PUBLIC UI MARKERS ==="
PUB=$(curl -fsS --max-time 20 https://cen-tral.duckdns.org/interfaz/)
grep -q 'selectionBar' <<<"$PUB"
grep -q 'toggleConversationSelection' <<<"$PUB"
grep -q 'deleteSelectedConversations' <<<"$PUB"
grep -q '550' <<<"$PUB"
echo CONVERSATION_LONGPRESS_MULTISELECT_PUBLIC_OK

echo CENTRAL_CONVERSATION_MULTISELECT_DELETE_V1_READY
echo "backup=$BACKUP"
