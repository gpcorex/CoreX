#!/usr/bin/env bash
set -euo pipefail

APP=/home/ubuntu/Interfaz
SERVICE=/etc/systemd/system/interfaz.service
CADDY=/etc/caddy/Caddyfile
PORT=8791
STAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "$APP"/{data,logs}
chown -R ubuntu:ubuntu "$APP"

cat >"$APP/server.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import json, os, re, sqlite3, time, urllib.request, urllib.error, uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

ROOT=Path("/home/ubuntu/Interfaz")
DB=ROOT/"data"/"interfaz.sqlite"
HOST="127.0.0.1"
PORT=8791
CENTRAL="http://127.0.0.1:8091"
OPENCLAW="http://127.0.0.1:18789/v1/chat/completions"
TOKEN_PATH=Path("/home/ubuntu/.openclaw/gateway.token")

ROOT.joinpath("data").mkdir(parents=True, exist_ok=True)

def db():
    c=sqlite3.connect(DB, timeout=10)
    c.row_factory=sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("""CREATE TABLE IF NOT EXISTS conversations(
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
    )""")
    c.execute("""CREATE TABLE IF NOT EXISTS messages(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'chat',
        job_id TEXT,
        created_at INTEGER NOT NULL
    )""")
    c.commit()
    return c

def now(): return int(time.time())

def jdump(obj): return json.dumps(obj, ensure_ascii=False).encode("utf-8")

def http_json(url, method="GET", payload=None, timeout=120, headers=None):
    data=None if payload is None else jdump(payload)
    h={"Content-Type":"application/json"}
    if headers: h.update(headers)
    req=urllib.request.Request(url, data=data, headers=h, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw=r.read()
        return json.loads(raw.decode("utf-8"))

ACTION_WORDS = (
    "creá","crea ","crear ","hacé ","hace ","hacer ","armá ","arma ","armar ",
    "agregá","agrega ","agregar ","modificá","modifica ","modificar ",
    "cambiá","cambia ","cambiar ","corregí","corrige ","corregir ",
    "eliminá","elimina ","eliminar ","borrá","borra ","borrar ",
    "instalá","instala ","instalar ","desplegá","despliega ","deploy",
    "reiniciá","reinicia ","reiniciar ","actualizá","actualiza ","actualizar ",
    "programá","programa ","programar ","implementá","implementa ","implementar "
)
TECH_WORDS = (
    "central","openclaw","vm","servicio","systemd","caddy","api","backend","frontend",
    "archivo","carpeta","directorio","python","javascript","node","github","repo",
    "base de datos","sqlite","puerto","script","interfaz","código","codigo","proyecto"
)

def is_operational(text:str)->bool:
    t=" "+text.lower().strip()+" "
    return any(w in t for w in ACTION_WORDS) and any(w in t for w in TECH_WORDS)

def ensure_conversation(cid:str|None, first_text:str=""):
    c=db()
    if not cid:
        cid="CV-"+uuid.uuid4().hex[:12]
    row=c.execute("SELECT id FROM conversations WHERE id=?",(cid,)).fetchone()
    if not row:
        title=(first_text.strip().replace("\n"," ")[:52] or "Nueva conversación")
        c.execute("INSERT INTO conversations(id,title,created_at,updated_at) VALUES(?,?,?,?)",
                  (cid,title,now(),now()))
        c.commit()
    c.close()
    return cid

def save_message(cid, role, content, kind="chat", job_id=None):
    c=db()
    c.execute("INSERT INTO messages(conversation_id,role,content,kind,job_id,created_at) VALUES(?,?,?,?,?,?)",
              (cid,role,content,kind,job_id,now()))
    c.execute("UPDATE conversations SET updated_at=? WHERE id=?",(now(),cid))
    c.commit(); c.close()

def history(cid, limit=18):
    c=db()
    rows=c.execute("SELECT role,content FROM messages WHERE conversation_id=? AND kind='chat' ORDER BY id DESC LIMIT ?",
                   (cid,limit)).fetchall()
    c.close()
    return [{"role":r["role"],"content":r["content"]} for r in reversed(rows)]

def call_openclaw(cid, text):
    token=TOKEN_PATH.read_text().strip()
    msgs=[{
        "role":"system",
        "content":(
            "Sos la capa conversacional de Interfaz. Respondé en español claro y natural. "
            "No afirmes haber ejecutado cambios en la VM. Las acciones técnicas se ejecutan por Central. "
            "Para conversación normal, ayudá directamente y mantené continuidad con el historial."
        )
    }]
    msgs.extend(history(cid, 16))
    # current user message is already in history because save_message happens before this call.
    payload={"model":"openclaw/default","messages":msgs,"stream":False}
    out=http_json(OPENCLAW,"POST",payload,120,{"Authorization":"Bearer "+token})
    return out["choices"][0]["message"]["content"].strip()

class H(BaseHTTPRequestHandler):
    def send_json(self, code, obj):
        raw=jdump(obj)
        self.send_response(code)
        self.send_header("Content-Type","application/json; charset=utf-8")
        self.send_header("Cache-Control","no-store")
        self.send_header("Content-Length",str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def read_json(self):
        n=int(self.headers.get("Content-Length","0") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        p=urlparse(self.path).path
        if p=="/api/health":
            return self.send_json(200,{"ok":True,"service":"interfaz","port":PORT})
        if p=="/api/conversations":
            c=db()
            rows=c.execute("SELECT id,title,created_at,updated_at FROM conversations ORDER BY updated_at DESC").fetchall()
            c.close()
            return self.send_json(200,{"ok":True,"conversations":[dict(r) for r in rows]})
        m=re.fullmatch(r"/api/conversations/([^/]+)",p)
        if m:
            cid=m.group(1)
            c=db()
            conv=c.execute("SELECT * FROM conversations WHERE id=?",(cid,)).fetchone()
            msgs=c.execute("SELECT id,role,content,kind,job_id,created_at FROM messages WHERE conversation_id=? ORDER BY id",
                           (cid,)).fetchall()
            c.close()
            if not conv: return self.send_json(404,{"ok":False,"error":"NOT_FOUND"})
            return self.send_json(200,{"ok":True,"conversation":dict(conv),"messages":[dict(x) for x in msgs]})
        m=re.fullmatch(r"/api/jobs/([^/]+)",p)
        if m:
            try:
                out=http_json(CENTRAL+"/api/jobs/"+m.group(1),timeout=8)
                return self.send_json(200,out)
            except Exception as e:
                return self.send_json(502,{"ok":False,"error":"CENTRAL_UNAVAILABLE","detail":str(e)})
        if p in ("/","/index.html"):
            raw=INDEX.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type","text/html; charset=utf-8")
            self.send_header("Cache-Control","no-store")
            self.send_header("Content-Length",str(len(raw)))
            self.end_headers(); self.wfile.write(raw); return
        return self.send_json(404,{"ok":False,"error":"NOT_FOUND"})

    def do_POST(self):
        p=urlparse(self.path).path
        if p=="/api/conversations":
            b=self.read_json()
            cid=ensure_conversation(None, str(b.get("title") or "Nueva conversación"))
            return self.send_json(201,{"ok":True,"conversation_id":cid})
        if p=="/api/message":
            try:
                b=self.read_json()
                text=str(b.get("text") or "").strip()
                if not text: return self.send_json(400,{"ok":False,"error":"TEXT_REQUIRED"})
                cid=ensure_conversation(str(b.get("conversation_id") or "") or None,text)
                save_message(cid,"user",text,"chat")
                if is_operational(text):
                    payload={
                        "task":text,
                        "source":"interfaz",
                        "project":str(b.get("project") or ""),
                        "conversation_id":cid
                    }
                    out=http_json(CENTRAL+"/api/jobs","POST",payload,8)
                    jid=out["job_id"]
                    save_message(cid,"assistant","Trabajo enviado a Central.","job",jid)
                    return self.send_json(202,{"ok":True,"mode":"job","conversation_id":cid,"job_id":jid,"status":out.get("status","RECIBIDA")})
                answer=call_openclaw(cid,text)
                save_message(cid,"assistant",answer,"chat")
                return self.send_json(200,{"ok":True,"mode":"chat","conversation_id":cid,"answer":answer})
            except urllib.error.HTTPError as e:
                return self.send_json(502,{"ok":False,"error":"UPSTREAM_HTTP","detail":e.read().decode("utf-8","ignore")[-1000:]})
            except Exception as e:
                return self.send_json(500,{"ok":False,"error":"MESSAGE_FAILED","detail":str(e)})
        return self.send_json(404,{"ok":False,"error":"NOT_FOUND"})

    def log_message(self, fmt, *args):
        pass

INDEX=r'''<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Interfaz</title>
<style>
:root{color-scheme:dark;--bg:#0f1115;--panel:#151922;--panel2:#1b202b;--line:#2a3140;--text:#eef2f7;--muted:#98a3b3;--accent:#d8dee9}
*{box-sizing:border-box}
html,body{height:100%;margin:0;background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
button,textarea{font:inherit}
.app{height:100%;display:grid;grid-template-columns:280px 1fr}
.side{border-right:1px solid var(--line);padding:16px;overflow:auto;background:#11141a}
.brand{font-weight:700;font-size:20px;margin:4px 0 16px}
.new{width:100%;border:1px solid var(--line);background:var(--panel);color:var(--text);padding:11px 12px;border-radius:12px;text-align:left}
.conv{margin-top:12px;display:flex;flex-direction:column;gap:6px}
.conv button{border:0;background:transparent;color:var(--muted);padding:9px 10px;border-radius:9px;text-align:left;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.conv button:hover,.conv button.active{background:var(--panel2);color:var(--text)}
.main{min-width:0;display:flex;flex-direction:column;height:100%}
.top{height:54px;border-bottom:1px solid var(--line);display:flex;align-items:center;padding:0 18px;font-size:14px;color:var(--muted)}
.messages{flex:1;overflow:auto;padding:24px 18px 150px}
.thread{max-width:820px;margin:0 auto}
.msg{margin:0 0 22px;line-height:1.55;white-space:pre-wrap;word-wrap:break-word}
.msg.user{margin-left:auto;background:var(--panel2);padding:12px 15px;border-radius:18px;max-width:82%;width:max-content}
.msg.assistant{max-width:100%}
.job{border:1px solid var(--line);background:var(--panel);border-radius:14px;padding:14px 15px;margin:8px 0 22px}
.job .status{font-weight:700;margin-bottom:7px}
.job .meta{font-size:12px;color:var(--muted)}
.composerWrap{position:fixed;left:280px;right:0;bottom:0;padding:16px 18px 20px;background:linear-gradient(transparent,var(--bg) 28%)}
.composer{max-width:820px;margin:auto;border:1px solid var(--line);background:var(--panel);border-radius:18px;padding:10px;display:flex;gap:10px;align-items:flex-end}
textarea{flex:1;resize:none;max-height:180px;min-height:48px;background:transparent;border:0;outline:0;color:var(--text);padding:12px;font-size:16px}
.send{width:44px;height:44px;border:0;border-radius:50%;background:var(--accent);color:#111;font-size:20px}
.empty{color:var(--muted);text-align:center;margin-top:20vh}
.mobileHead{display:none}
@media(max-width:760px){
 .app{display:block}.side{position:fixed;z-index:5;inset:0 22% 0 0;transform:translateX(-105%);transition:.2s;box-shadow:20px 0 50px #0008}
 .side.open{transform:translateX(0)}.main{height:100%}.composerWrap{left:0}
 .mobileHead{display:inline-block;margin-right:12px;background:none;border:0;color:var(--text);font-size:22px}
 .top{padding-left:10px}.messages{padding-left:14px;padding-right:14px}.msg.user{max-width:90%}
}
</style>
</head>
<body>
<div class="app">
<aside class="side" id="side">
 <div class="brand">Interfaz</div>
 <button class="new" id="newBtn">＋ Nueva conversación</button>
 <div class="conv" id="conv"></div>
</aside>
<main class="main">
 <div class="top"><button class="mobileHead" id="menu">☰</button><span id="title">Nueva conversación</span></div>
 <div class="messages" id="messages"><div class="thread" id="thread"><div class="empty">Escribí para empezar.</div></div></div>
 <div class="composerWrap"><div class="composer">
   <textarea id="input" rows="1" placeholder="Escribí un mensaje..."></textarea>
   <button class="send" id="send">➤</button>
 </div></div>
</main>
</div>
<script>
let cid=null, polling=new Map();
const $=s=>document.querySelector(s);
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
async function api(url,opt){const r=await fetch(url,opt);const j=await r.json();if(!r.ok)throw new Error(j.detail||j.error||r.status);return j}
function scrollEnd(){$('#messages').scrollTop=$('#messages').scrollHeight}
function addMsg(role,text){$('.empty')?.remove();const d=document.createElement('div');d.className='msg '+role;d.innerHTML=esc(text);$('#thread').appendChild(d);scrollEnd()}
function addJob(jid,status='RECIBIDA'){
 $('.empty')?.remove();const d=document.createElement('div');d.className='job';d.id='job-'+jid;
 d.innerHTML='<div class="status">'+esc(status)+'</div><div class="meta">'+esc(jid)+'</div>';
 $('#thread').appendChild(d);scrollEnd();pollJob(jid)
}
async function pollJob(jid){
 if(polling.has(jid))return; polling.set(jid,true)
 let last=''
 for(let i=0;i<360;i++){
   try{
     const x=await api('api/jobs/'+encodeURIComponent(jid)); const j=x.job||{}
     const el=$('#job-'+jid); if(el){el.querySelector('.status').textContent=j.status||'—'}
     if(j.status==='COMPLETADA'||j.status==='ERROR'){
       if(el){
         let txt=''
         if(j.status==='COMPLETADA'){
           if(j.result&&j.result.message) txt=j.result.message
           else if(typeof j.result==='string') txt=j.result
           else txt='Trabajo completado y verificado.'
         } else txt='El trabajo terminó con error'+(j.error?': '+j.error:'')
         const r=document.createElement('div');r.style.marginTop='10px';r.textContent=txt;el.appendChild(r)
       }
       break
     }
   }catch(e){}
   await new Promise(r=>setTimeout(r,1500))
 }
 polling.delete(jid); loadConvs()
}
async function loadConvs(){
 try{
  const x=await api('api/conversations'); const box=$('#conv'); box.innerHTML=''
  for(const c of x.conversations){const b=document.createElement('button');b.textContent=c.title;b.className=c.id===cid?'active':'';b.onclick=()=>openConv(c.id);box.appendChild(b)}
 }catch(e){}
}
async function openConv(id){
 cid=id; $('#side').classList.remove('open')
 const x=await api('api/conversations/'+encodeURIComponent(id)); $('#thread').innerHTML=''; $('#title').textContent=x.conversation.title
 for(const m of x.messages){
   if(m.kind==='job'&&m.job_id) addJob(m.job_id,'RECIBIDA')
   else addMsg(m.role,m.content)
 }
 loadConvs()
}
async function newConv(){cid=null;$('#title').textContent='Nueva conversación';$('#thread').innerHTML='<div class="empty">Escribí para empezar.</div>';loadConvs()}
async function send(){
 const t=$('#input').value.trim(); if(!t)return
 $('#input').value=''; resize(); addMsg('user',t); $('#send').disabled=true
 try{
   const x=await api('api/message',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({conversation_id:cid,text:t})})
   cid=x.conversation_id
   if(x.mode==='chat') addMsg('assistant',x.answer)
   else if(x.mode==='job') addJob(x.job_id,x.status)
   loadConvs()
 }catch(e){addMsg('assistant','Error: '+e.message)}
 finally{$('#send').disabled=false}
}
function resize(){const i=$('#input');i.style.height='auto';i.style.height=Math.min(i.scrollHeight,180)+'px'}
$('#send').onclick=send;$('#newBtn').onclick=newConv;$('#menu').onclick=()=>$('#side').classList.toggle('open')
$('#input').addEventListener('input',resize)
$('#input').addEventListener('keydown',e=>{if(e.key==='Enter'&&(e.ctrlKey||e.metaKey)){e.preventDefault();send()}})
loadConvs()
</script>
</body></html>'''

if __name__=="__main__":
    ThreadingHTTPServer((HOST,PORT),H).serve_forever()
PY

chown -R ubuntu:ubuntu "$APP"
chmod 755 "$APP/server.py"

cat >"$SERVICE" <<'UNIT'
[Unit]
Description=Interfaz conversational UI
After=network-online.target central-jobs-api.service
Wants=network-online.target
Requires=central-jobs-api.service

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/home/ubuntu/Interfaz
ExecStart=/usr/bin/python3 /home/ubuntu/Interfaz/server.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now interfaz.service
systemctl restart interfaz.service

for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:$PORT/api/health >/tmp/interfaz-health.json 2>/dev/null; then break; fi
  sleep 1
done

if ! grep -q 'route /interfaz/\*' "$CADDY"; then
python3 - <<'PY'
from pathlib import Path
p=Path("/etc/caddy/Caddyfile")
s=p.read_text()
needle='''    route {
        reverse_proxy 127.0.0.1:8090
    }
'''
insert='''    route /interfaz {
        redir /interfaz/ 308
    }

    route /interfaz/* {
        uri strip_prefix /interfaz
        reverse_proxy 127.0.0.1:8791
    }

'''
if needle not in s:
    raise SystemExit("CADDY_CATCHALL_NOT_FOUND")
s=s.replace(needle,insert+needle,1)
p.write_text(s)
PY
fi

caddy validate --config "$CADDY"
systemctl reload caddy

echo "=== HEALTH ==="
cat /tmp/interfaz-health.json
echo

echo "=== ROUTE ==="
curl -fsSI --max-time 10 https://cen-tral.duckdns.org/interfaz/ | head -n 1 || true

echo "=== SERVICES ==="
systemctl is-active interfaz.service
systemctl is-active central-jobs-api.service

echo "=== PORTS ==="
ss -ltnp | grep -E ':(8791|8091|18789)\b' || true

echo "INTERFAZ_V1_READY"
echo "URL=https://cen-tral.duckdns.org/interfaz/"
