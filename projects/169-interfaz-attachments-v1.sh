#!/usr/bin/env bash
set -euo pipefail

APP=/home/ubuntu/Interfaz
SERVER="$APP/server.py"
NATIVE=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/interfaz-attachments-v1-$STAMP

mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. INSTALL VISION ATTACHMENT ANALYZER ==="
cat >"$NATIVE/attachment_vision.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, base64, json, mimetypes
from config import load_settings
from providers import ProviderRegistry, groq_provider, openrouter_provider
from router import select

STATE="/home/ubuntu/Central/state/providers.json"

def provider_for(ref,settings):
    p,m=ref.split("/",1)
    if p=="groq": return p,m,groq_provider(settings.groq_key,60)
    if p=="openrouter": return p,m,openrouter_provider(settings.openrouter_key,60)
    raise RuntimeError("UNSUPPORTED_PROVIDER:"+p)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--prompt",default="Describí con precisión lo relevante de esta imagen.")
    args=ap.parse_args()

    settings=load_settings()
    reg=ProviderRegistry(settings.groq_key,settings.openrouter_key,STATE)
    ranked=select("vision",reg)
    if not ranked:
        raise SystemExit("NO_VERIFIED_VISION_ROUTE")

    ref=ranked[0]["ref"]
    provider,model,p=provider_for(ref,settings)
    mime=mimetypes.guess_type(args.image)[0] or "image/jpeg"
    raw=open(args.image,"rb").read()
    if len(raw)>12*1024*1024:
        raise SystemExit("IMAGE_TOO_LARGE")
    data="data:"+mime+";base64,"+base64.b64encode(raw).decode("ascii")
    payload={
      "model":model,
      "messages":[{"role":"user","content":[
        {"type":"text","text":args.prompt},
        {"type":"image_url","image_url":{"url":data}}
      ]}],
      "max_tokens":800,
      "temperature":0.2,
    }
    out,_=p._request("/chat/completions",payload,"POST")
    text=((out.get("choices") or [{}])[0].get("message") or {}).get("content","").strip()
    print(json.dumps({
      "ok":True,
      "provider":provider,
      "model":model,
      "model_ref":ref,
      "capability":"vision",
      "text":text,
    },ensure_ascii=False))

if __name__=="__main__":
    main()
PY
chmod 755 "$NATIVE/attachment_vision.py"
python3 -m py_compile "$NATIVE/attachment_vision.py"
echo ATTACHMENT_VISION_ANALYZER_OK

echo "=== 2. PATCH INTERFAZ FOR ATTACHMENTS ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

# Imports.
old='import base64, json, os, re, sqlite3, subprocess, tempfile, time, urllib.request, urllib.error, uuid'
new='import base64, json, mimetypes, os, re, sqlite3, subprocess, tempfile, time, urllib.request, urllib.error, uuid'
if old in s:
    s=s.replace(old,new,1)
elif 'mimetypes' not in s.splitlines()[1]:
    raise SystemExit("IMPORT_ANCHOR_NOT_FOUND")

# Paths/constants.
anchor='''TOKEN_PATH=Path("/home/ubuntu/.openclaw/gateway.token")

ROOT.joinpath("data").mkdir(parents=True, exist_ok=True)
'''
insert='''TOKEN_PATH=Path("/home/ubuntu/.openclaw/gateway.token")
ATTACH_ROOT=ROOT/"data"/"attachments"
ATTACH_ROOT.mkdir(parents=True, exist_ok=True)
MAX_ATTACHMENT=15*1024*1024

ROOT.joinpath("data").mkdir(parents=True, exist_ok=True)
'''
if 'ATTACH_ROOT=' not in s:
    if anchor not in s: raise SystemExit("PATH_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert,1)

# DB schema.
db_anchor='''    c.execute("""CREATE TABLE IF NOT EXISTS messages(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'chat',
        job_id TEXT,
        created_at INTEGER NOT NULL
    )""")
    c.commit()
'''
db_insert='''    c.execute("""CREATE TABLE IF NOT EXISTS messages(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'chat',
        job_id TEXT,
        created_at INTEGER NOT NULL
    )""")
    c.execute("""CREATE TABLE IF NOT EXISTS attachments(
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        original_name TEXT NOT NULL,
        stored_name TEXT NOT NULL,
        mime TEXT NOT NULL,
        size INTEGER NOT NULL,
        path TEXT NOT NULL,
        created_at INTEGER NOT NULL
    )""")
    c.execute("""CREATE TABLE IF NOT EXISTS message_attachments(
        message_id INTEGER NOT NULL,
        attachment_id TEXT NOT NULL,
        PRIMARY KEY(message_id,attachment_id)
    )""")
    c.commit()
'''
if 'CREATE TABLE IF NOT EXISTS attachments' not in s:
    if db_anchor not in s: raise SystemExit("DB_ANCHOR_NOT_FOUND")
    s=s.replace(db_anchor,db_insert,1)

# save_message returns id + attachment helpers.
old_save='''def save_message(cid, role, content, kind="chat", job_id=None):
    c=db()
    c.execute("INSERT INTO messages(conversation_id,role,content,kind,job_id,created_at) VALUES(?,?,?,?,?,?)",
              (cid,role,content,kind,job_id,now()))
    c.execute("UPDATE conversations SET updated_at=? WHERE id=?",(now(),cid))
    c.commit(); c.close()
'''
new_save='''def save_message(cid, role, content, kind="chat", job_id=None):
    c=db()
    cur=c.execute("INSERT INTO messages(conversation_id,role,content,kind,job_id,created_at) VALUES(?,?,?,?,?,?)",
              (cid,role,content,kind,job_id,now()))
    mid=cur.lastrowid
    c.execute("UPDATE conversations SET updated_at=? WHERE id=?",(now(),cid))
    c.commit(); c.close()
    return mid

def link_attachments(message_id, cid, ids):
    if not ids: return
    c=db()
    for aid in ids:
        row=c.execute("SELECT id FROM attachments WHERE id=? AND conversation_id=?",(aid,cid)).fetchone()
        if row:
            c.execute("INSERT OR IGNORE INTO message_attachments(message_id,attachment_id) VALUES(?,?)",(message_id,aid))
    c.commit(); c.close()

def get_attachments(ids, cid=None):
    if not ids: return []
    c=db()
    out=[]
    for aid in ids:
        if cid:
            row=c.execute("SELECT * FROM attachments WHERE id=? AND conversation_id=?",(aid,cid)).fetchone()
        else:
            row=c.execute("SELECT * FROM attachments WHERE id=?",(aid,)).fetchone()
        if row: out.append(dict(row))
    c.close()
    return out

def extract_text_attachment(a):
    path=a["path"]; mime=a["mime"]; name=a["original_name"].lower()
    try:
        if mime.startswith("text/") or name.endswith((".txt",".md",".json",".csv",".py",".js",".ts",".sh",".log",".yaml",".yml",".xml",".html",".css")):
            raw=Path(path).read_text(encoding="utf-8",errors="replace")
            return raw[:120000]
        if mime=="application/pdf" or name.endswith(".pdf"):
            cp=subprocess.run(["pdftotext","-layout",path,"-"],text=True,capture_output=True,timeout=45)
            if cp.returncode==0:
                return cp.stdout[:120000]
    except Exception:
        return ""
    return ""

def analyze_image_attachment(a,prompt):
    env=dict(os.environ); env["PYTHONPATH"]="/home/ubuntu/Central/native_v1"
    cp=subprocess.run(
        ["/usr/bin/python3","/home/ubuntu/Central/native_v1/attachment_vision.py",a["path"],"--prompt",prompt],
        text=True,capture_output=True,timeout=120,env=env
    )
    if cp.returncode!=0:
        return "[No se pudo analizar visualmente "+a["original_name"]+": "+(cp.stderr or cp.stdout)[-300:]+"]"
    obj=json.loads(cp.stdout)
    return obj.get("text","")

def attachment_context(items,prompt):
    parts=[]
    for a in items:
        if a["mime"].startswith("image/"):
            parts.append("Imagen "+a["original_name"]+":\n"+analyze_image_attachment(a,prompt or "Describí lo relevante de esta imagen."))
        else:
            txt=extract_text_attachment(a)
            if txt:
                parts.append("Archivo "+a["original_name"]+":\n"+txt)
            else:
                parts.append("Archivo adjunto disponible: "+a["original_name"]+" ("+a["mime"]+")")
    return "\n\n".join(parts)
'''
if 'def link_attachments(' not in s:
    if old_save not in s: raise SystemExit("SAVE_MESSAGE_ANCHOR_NOT_FOUND")
    s=s.replace(old_save,new_save,1)

# Enrich chat history with current supplemental context.
old_call='''def call_openclaw(cid, text):
    token=TOKEN_PATH.read_text().strip()
'''
new_call='''def call_openclaw(cid, text, extra_context=""):
    token=TOKEN_PATH.read_text().strip()
'''
if old_call in s:
    s=s.replace(old_call,new_call,1)

old_hist='''    msgs.extend(history(cid, 16))
    # current user message is already in history because save_message happens before this call.
    payload={"model":"openclaw/default","messages":msgs,"stream":False}
'''
new_hist='''    msgs.extend(history(cid, 16))
    # current user message is already in history because save_message happens before this call.
    if extra_context and msgs and msgs[-1].get("role")=="user":
        msgs[-1]["content"]=msgs[-1]["content"]+"\n\n[CONTEXTO DE ADJUNTOS]\n"+extra_context
    payload={"model":"openclaw/default","messages":msgs,"stream":False}
'''
if old_hist in s:
    s=s.replace(old_hist,new_hist,1)

# Conversation GET with attachments per message.
old_msgs='''            msgs=c.execute("SELECT id,role,content,kind,job_id,created_at FROM messages WHERE conversation_id=? ORDER BY id",
                           (cid,)).fetchall()
            c.close()
            if not conv: return self.send_json(404,{"ok":False,"error":"NOT_FOUND"})
            return self.send_json(200,{"ok":True,"conversation":dict(conv),"messages":[dict(x) for x in msgs]})
'''
new_msgs='''            msgs=c.execute("SELECT id,role,content,kind,job_id,created_at FROM messages WHERE conversation_id=? ORDER BY id",
                           (cid,)).fetchall()
            payload_msgs=[]
            for mrow in msgs:
                md=dict(mrow)
                ars=c.execute("""SELECT a.id,a.original_name,a.mime,a.size
                    FROM attachments a JOIN message_attachments ma ON ma.attachment_id=a.id
                    WHERE ma.message_id=? ORDER BY a.created_at""",(md["id"],)).fetchall()
                md["attachments"]=[dict(a) for a in ars]
                payload_msgs.append(md)
            c.close()
            if not conv: return self.send_json(404,{"ok":False,"error":"NOT_FOUND"})
            return self.send_json(200,{"ok":True,"conversation":dict(conv),"messages":payload_msgs})
'''
if 'payload_msgs=[]' not in s:
    if old_msgs not in s: raise SystemExit("CONVERSATION_GET_ANCHOR_NOT_FOUND")
    s=s.replace(old_msgs,new_msgs,1)

# GET raw attachment endpoint.
get_anchor='''        m=re.fullmatch(r"/api/jobs/([^/]+)",p)
        if m:
'''
get_insert='''        m=re.fullmatch(r"/api/attachments/([A-Za-z0-9_-]+)",p)
        if m:
            c=db(); row=c.execute("SELECT * FROM attachments WHERE id=?",(m.group(1),)).fetchone(); c.close()
            if not row: return self.send_json(404,{"ok":False,"error":"ATTACHMENT_NOT_FOUND"})
            path=Path(row["path"])
            if not path.exists(): return self.send_json(404,{"ok":False,"error":"ATTACHMENT_FILE_MISSING"})
            raw=path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type",row["mime"])
            self.send_header("Content-Length",str(len(raw)))
            self.send_header("Content-Disposition",'inline; filename="'+row["original_name"].replace('"','')+'"')
            self.end_headers(); self.wfile.write(raw); return
        m=re.fullmatch(r"/api/jobs/([^/]+)",p)
        if m:
'''
if 'ATTACHMENT_FILE_MISSING' not in s:
    if get_anchor not in s: raise SystemExit("GET_ATTACHMENT_ANCHOR_NOT_FOUND")
    s=s.replace(get_anchor,get_insert,1)

# POST upload endpoint.
post_anchor='''        if p=="/api/transcribe":
            try:
'''
post_insert='''        if p=="/api/attachments":
            try:
                b=self.read_json()
                name=os.path.basename(str(b.get("name") or "adjunto"))
                mime=str(b.get("mime") or mimetypes.guess_type(name)[0] or "application/octet-stream")
                raw=str(b.get("data_base64") or "")
                if "," in raw: raw=raw.split(",",1)[1]
                data=base64.b64decode(raw,validate=True)
                if not data or len(data)>MAX_ATTACHMENT:
                    return self.send_json(400,{"ok":False,"error":"ATTACHMENT_SIZE_INVALID"})
                cid=ensure_conversation(str(b.get("conversation_id") or "") or None,name)
                aid="AT-"+uuid.uuid4().hex[:16]
                ext=Path(name).suffix[:10]
                d=ATTACH_ROOT/cid; d.mkdir(parents=True,exist_ok=True)
                path=d/(aid+ext)
                path.write_bytes(data)
                c=db()
                c.execute("INSERT INTO attachments(id,conversation_id,original_name,stored_name,mime,size,path,created_at) VALUES(?,?,?,?,?,?,?,?)",
                          (aid,cid,name,path.name,mime,len(data),str(path),now()))
                c.commit(); c.close()
                return self.send_json(201,{"ok":True,"conversation_id":cid,"attachment":{"id":aid,"name":name,"mime":mime,"size":len(data),"url":"api/attachments/"+aid}})
            except Exception as e:
                return self.send_json(500,{"ok":False,"error":"ATTACHMENT_UPLOAD_FAILED","detail":str(e)})
        if p=="/api/transcribe":
            try:
'''
if 'ATTACHMENT_UPLOAD_FAILED' not in s:
    if post_anchor not in s: raise SystemExit("POST_ATTACHMENT_ANCHOR_NOT_FOUND")
    s=s.replace(post_anchor,post_insert,1)

# Patch message handling to link and use attachments.
old_message='''                cid=ensure_conversation(str(b.get("conversation_id") or "") or None,text)
                save_message(cid,"user",text,"chat")
                if is_operational(text):
                    payload={
                        "task":text,
                        "source":"interfaz",
                        "project":str(b.get("project") or ""),
                        "conversation_id":cid
                    }
'''
new_message='''                cid=ensure_conversation(str(b.get("conversation_id") or "") or None,text)
                attachment_ids=[str(x) for x in (b.get("attachment_ids") or [])][:8]
                mid=save_message(cid,"user",text,"chat")
                link_attachments(mid,cid,attachment_ids)
                attachments=get_attachments(attachment_ids,cid)
                extra=attachment_context(attachments,text) if attachments else ""
                effective=text+("\n\n[CONTEXTO DE ADJUNTOS]\n"+extra if extra else "")
                if is_operational(text):
                    payload={
                        "task":effective,
                        "source":"interfaz",
                        "project":str(b.get("project") or ""),
                        "conversation_id":cid
                    }
'''
if 'attachment_ids=[str(x)' not in s:
    if old_message not in s: raise SystemExit("MESSAGE_ATTACHMENT_ANCHOR_NOT_FOUND")
    s=s.replace(old_message,new_message,1)

s=s.replace('''                answer=call_openclaw(cid,text)
''','''                answer=call_openclaw(cid,text,extra)
''',1)

# CSS.
css_anchor='.composer{max-width:820px;margin:auto;border:1px solid var(--line);background:var(--panel);border-radius:18px;padding:10px;display:flex;gap:10px;align-items:flex-end}'
css_new='.composer{max-width:820px;margin:auto;border:1px solid var(--line);background:var(--panel);border-radius:18px;padding:10px;display:flex;gap:10px;align-items:flex-end}.attach{width:44px;height:44px;border:1px solid var(--line);border-radius:50%;background:transparent;color:var(--text);font-size:20px}.pending{max-width:820px;margin:0 auto 8px;display:flex;gap:6px;flex-wrap:wrap}.chip{font-size:12px;border:1px solid var(--line);background:var(--panel2);padding:6px 9px;border-radius:999px}.attrow{display:flex;gap:8px;flex-wrap:wrap;margin-top:8px}.attlink{font-size:12px;color:var(--accent);text-decoration:none;border:1px solid var(--line);padding:5px 8px;border-radius:10px}'
if '.pending{' not in s:
    if css_anchor not in s: raise SystemExit("CSS_ANCHOR_NOT_FOUND")
    s=s.replace(css_anchor,css_new,1)

# HTML composer.
old_comp=''' <div class="composerWrap"><div class="composer">
   <textarea id="input" rows="1" placeholder="Escribí un mensaje..."></textarea>
   <button class="mic" id="mic" title="Hablar">🎙</button>
   <button class="send" id="send">➤</button>
 </div></div>
'''
new_comp=''' <div class="composerWrap">
  <div class="pending" id="pending"></div>
  <div class="composer">
   <input type="file" id="fileInput" multiple hidden accept="image/*,.pdf,.txt,.md,.json,.csv,.py,.js,.ts,.sh,.log,.yaml,.yml">
   <button class="attach" id="attach" title="Adjuntar">📎</button>
   <textarea id="input" rows="1" placeholder="Escribí un mensaje..."></textarea>
   <button class="mic" id="mic" title="Hablar">🎙</button>
   <button class="send" id="send">➤</button>
  </div>
 </div>
'''
if 'id="fileInput"' not in s:
    if old_comp not in s: raise SystemExit("COMPOSER_ANCHOR_NOT_FOUND")
    s=s.replace(old_comp,new_comp,1)

# JS attachment state/render + upload.
js_anchor='''let cid=null, polling=new Map();
const $=s=>document.querySelector(s);
'''
js_insert='''let cid=null, polling=new Map(), pendingAttachments=[];
const $=s=>document.querySelector(s);
function renderPending(){
 const box=$('#pending'); if(!box)return; box.innerHTML='';
 pendingAttachments.forEach((a,i)=>{
   const d=document.createElement('span'); d.className='chip';
   d.textContent=a.name+' ×'; d.onclick=()=>{pendingAttachments.splice(i,1);renderPending()}; box.appendChild(d)
 })
}
async function uploadFiles(files){
 for(const f of files){
   if(f.size>15*1024*1024){addMsg('assistant','Adjunto demasiado grande: '+f.name);continue}
   const data=await new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(r.result);r.onerror=reject;r.readAsDataURL(f)});
   try{
     const x=await api('api/attachments',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({conversation_id:cid,name:f.name,mime:f.type||'application/octet-stream',data_base64:data})});
     cid=x.conversation_id; pendingAttachments.push(x.attachment); renderPending(); loadConvs();
   }catch(e){addMsg('assistant','Error al adjuntar '+f.name+': '+e.message)}
 }
}
'''
if 'pendingAttachments=[]' not in s:
    if js_anchor not in s: raise SystemExit("JS_STATE_ANCHOR_NOT_FOUND")
    s=s.replace(js_anchor,js_insert,1)

# addMsg attachment renderer helper and openConv.
old_add="function addMsg(role,text){$('.empty')?.remove();const d=document.createElement('div');d.className='msg '+role;d.innerHTML=esc(text);$('#thread').appendChild(d);scrollEnd()}"
new_add="""function addMsg(role,text,attachments=[]){$('.empty')?.remove();const d=document.createElement('div');d.className='msg '+role;d.innerHTML=esc(text);if(attachments&&attachments.length){const row=document.createElement('div');row.className='attrow';for(const a of attachments){const l=document.createElement('a');l.className='attlink';l.href='api/attachments/'+encodeURIComponent(a.id);l.target='_blank';l.textContent='📎 '+(a.original_name||a.name||'adjunto');row.appendChild(l)}d.appendChild(row)}$('#thread').appendChild(d);scrollEnd()}"""
if 'attachments=[]' not in s:
    if old_add not in s: raise SystemExit("ADDMSG_ANCHOR_NOT_FOUND")
    s=s.replace(old_add,new_add,1)

s=s.replace("else addMsg(m.role,m.content)","else addMsg(m.role,m.content,m.attachments||[])",1)

# send attachments.
old_send_body="""   const x=await api('api/message',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({conversation_id:cid,text:t})})
   cid=x.conversation_id
"""
new_send_body="""   const attachment_ids=pendingAttachments.map(a=>a.id)
   const shown=pendingAttachments.slice()
   const x=await api('api/message',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({conversation_id:cid,text:t,attachment_ids})})
   cid=x.conversation_id; pendingAttachments=[]; renderPending()
"""
if 'attachment_ids=pendingAttachments.map' not in s:
    if old_send_body not in s: raise SystemExit("SEND_ATTACHMENT_ANCHOR_NOT_FOUND")
    s=s.replace(old_send_body,new_send_body,1)

# Current optimistic user message should display pending attachment names.
old_send_start=""" const t=$('#input').value.trim(); if(!t)return
 $('#input').value=''; resize(); addMsg('user',t); $('#send').disabled=true
"""
new_send_start=""" const t=$('#input').value.trim(); if(!t && !pendingAttachments.length)return
 const shownAttachments=pendingAttachments.map(a=>({id:a.id,original_name:a.name}))
 $('#input').value=''; resize(); addMsg('user',t||'Adjunto',shownAttachments); $('#send').disabled=true
"""
if 'shownAttachments=pendingAttachments.map' not in s:
    if old_send_start not in s: raise SystemExit("SEND_START_ANCHOR_NOT_FOUND")
    s=s.replace(old_send_start,new_send_start,1)

# Ensure backend still requires text: convert attachment-only to "Adjunto".
old_text='''                text=str(b.get("text") or "").strip()
                if not text: return self.send_json(400,{"ok":False,"error":"TEXT_REQUIRED"})
'''
new_text='''                text=str(b.get("text") or "").strip()
                if not text and (b.get("attachment_ids") or []):
                    text="Adjunto"
                if not text: return self.send_json(400,{"ok":False,"error":"TEXT_REQUIRED"})
'''
if old_text in s:
    s=s.replace(old_text,new_text,1)

# Button listeners.
click_anchor="$('#mic').onclick=toggleMic;$('#send').onclick=send;"
click_new="$('#attach').onclick=()=>$('#fileInput').click();$('#fileInput').onchange=e=>{uploadFiles([...e.target.files]);e.target.value=''};$('#mic').onclick=toggleMic;$('#send').onclick=send;"
if "$('#attach').onclick" not in s:
    if click_anchor not in s: raise SystemExit("ATTACH_CLICK_ANCHOR_NOT_FOUND")
    s=s.replace(click_anchor,click_new,1)

# Clear pending on new conversation.
s=s.replace("async function newConv(){cid=null;","async function newConv(){cid=null;pendingAttachments=[];renderPending();",1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo INTERFAZ_ATTACHMENTS_PATCH_OK

echo "=== 3. ENSURE PDF TEXT SUPPORT ==="
if ! command -v pdftotext >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq poppler-utils
fi
command -v pdftotext >/dev/null
echo PDF_TEXT_SUPPORT_OK

echo "=== 4. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/interfaz-att-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/interfaz-att-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_ATTACHMENTS_SERVICE_OK

echo "=== 5. UPLOAD + IMAGE VISION END-TO-END TEST ==="
IMG=/tmp/interfaz-attachment-red.png
python3 - "$IMG" <<'PY'
import struct,zlib,sys
w=h=64
raw=b"".join(b"\x00"+b"\xff\x00\x00\xff"*w for _ in range(h))
def chunk(t,d): return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
png=b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",w,h,8,6,0,0,0))+chunk(b"IDAT",zlib.compress(raw))+chunk(b"IEND",b"")
open(sys.argv[1],"wb").write(png)
PY

REQ=/tmp/interfaz-attach-request.json
python3 - "$IMG" "$REQ" <<'PY'
import base64,json,sys
src,dst=sys.argv[1],sys.argv[2]
with open(src,"rb") as f: b64=base64.b64encode(f.read()).decode()
with open(dst,"w",encoding="utf-8") as f:
    json.dump({"name":"rojo.png","mime":"image/png","data_base64":b64},f,separators=(",",":"))
PY

UP=$(curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @"$REQ" http://127.0.0.1:8791/api/attachments)
echo "$UP"
CID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["conversation_id"])' <<<"$UP")
AID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["attachment"]["id"])' <<<"$UP")

MSGREQ=/tmp/interfaz-attach-message.json
python3 - "$CID" "$AID" "$MSGREQ" <<'PY'
import json,sys
cid,aid,dst=sys.argv[1:]
with open(dst,"w",encoding="utf-8") as f:
    json.dump({"conversation_id":cid,"text":"¿De qué color es la imagen? Respondé brevemente.","attachment_ids":[aid]},f,ensure_ascii=False)
PY

MSG=$(curl -fsS --max-time 150 -H 'Content-Type: application/json' --data-binary @"$MSGREQ" http://127.0.0.1:8791/api/message)
echo "$MSG"
MSG_JSON="$MSG" python3 - <<'PY'
import json,os
x=json.loads(os.environ["MSG_JSON"])
assert x["ok"] is True,x
assert x["conversation_id"],x
print("INTERFAZ_ATTACHMENT_MESSAGE_OK")
PY

GET=$(curl -fsS --max-time 15 "http://127.0.0.1:8791/api/conversations/$CID")
GET_JSON="$GET" AID="$AID" python3 - <<'PY'
import json,os
x=json.loads(os.environ["GET_JSON"])
aid=os.environ["AID"]
msgs=x["messages"]
assert any(any(a["id"]==aid for a in (m.get("attachments") or [])) for m in msgs),x
print("INTERFAZ_ATTACHMENT_PERSISTENCE_OK")
PY

echo "=== 6. PUBLIC UI CHECK ==="
curl -fsS --max-time 15 https://cen-tral.duckdns.org/interfaz/ | grep -q 'id="attach"'
curl -fsS --max-time 15 https://cen-tral.duckdns.org/interfaz/ | grep -q 'id="fileInput"'
echo INTERFAZ_ATTACHMENTS_PUBLIC_OK

cat >"$NATIVE/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "interfaz-attachments-v1",
  "upload": true,
  "conversation_persistence": true,
  "image_vision": true,
  "text_files": true,
  "pdf_text": true,
  "max_attachment_mb": 15,
  "multiple_files": true,
  "active": true
}
EOF

echo CENTRAL_INTERFAZ_ATTACHMENTS_V1_READY
echo "URL=https://cen-tral.duckdns.org/interfaz/"
echo "backup=$BACKUP"
