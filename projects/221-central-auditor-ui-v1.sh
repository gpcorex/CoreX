#!/usr/bin/env bash
set -euo pipefail

APP=/home/ubuntu/Central/auditor_ui_v1
SERVICE=/etc/systemd/system/central-auditor-ui.service
CADDY=/etc/caddy/Caddyfile
PORT=8792
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/auditor-ui-v1-$STAMP

mkdir -p "$APP" "$APP/data" /home/ubuntu/Central/inbox /home/ubuntu/Central/logs/auditor "$BACKUP"

echo "=== 1. INSTALL AUDITOR UI SERVICE ==="
cat >"$APP/server.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import json, os, re, subprocess, threading, time, uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

HOST="127.0.0.1"
PORT=8792
ROOT=Path("/home/ubuntu/Central/auditor_ui_v1")
DATA=ROOT/"data"
INBOX=Path("/home/ubuntu/Central/inbox")
LOGS=Path("/home/ubuntu/Central/logs/auditor")
PIPE=Path("/home/ubuntu/Central/pipeline_v1/run_android_pipeline.py")
RUNS=DATA/"runs.json"
MAX_UPLOAD=2*1024*1024*1024

for p in (DATA,INBOX,LOGS): p.mkdir(parents=True,exist_ok=True)
LOCK=threading.Lock()

def now():
    return int(time.time())

def load_runs():
    try:
        x=json.loads(RUNS.read_text(encoding="utf-8"))
        return x if isinstance(x,list) else []
    except Exception:
        return []

def save_runs(rows):
    tmp=RUNS.with_suffix(".tmp")
    tmp.write_text(json.dumps(rows,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    tmp.replace(RUNS)

def update_run(rid, **changes):
    with LOCK:
        rows=load_runs()
        found=None
        for r in rows:
            if r.get("id")==rid:
                r.update(changes); found=r; break
        if found is None:
            found={"id":rid}; found.update(changes); rows.insert(0,found)
        save_runs(rows[:100])
        return found

def get_run(rid):
    for r in load_runs():
        if r.get("id")==rid:return r
    return None

def safe_filename(name):
    name=Path(name or "app.apk").name
    name=re.sub(r"[^A-Za-z0-9._-]+","_",name)[:180]
    return name or "app.apk"

def worker(rid, path, kind, display_name):
    logp=LOGS/f"{rid}.log"
    started=now()
    update_run(rid,status="RUNNING",started_at=started,log_path=str(logp))
    cmd=["/usr/bin/python3",str(PIPE),str(path),"--kind",kind,"--name",display_name]
    with logp.open("a",encoding="utf-8",buffering=1) as log:
        log.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] START {rid}\n")
        log.write("source="+str(path)+"\n")
        log.write("kind="+kind+"\n")
        try:
            cp=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
            last_json=None
            assert cp.stdout is not None
            for line in cp.stdout:
                log.write(line)
                line=line.strip()
                if line.startswith("{") and line.endswith("}"):
                    try:last_json=json.loads(line)
                    except Exception:pass
            rc=cp.wait()
            if rc==0 and isinstance(last_json,dict) and last_json.get("ok"):
                project_id=last_json.get("project_id")
                update_run(
                    rid,status="COMPLETED",finished_at=now(),returncode=rc,
                    project_id=project_id,result=last_json
                )
                log.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] COMPLETED project_id={project_id}\n")
            else:
                update_run(rid,status="ERROR",finished_at=now(),returncode=rc,result=last_json)
                log.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] ERROR returncode={rc}\n")
        except Exception as e:
            update_run(rid,status="ERROR",finished_at=now(),error=str(e))
            log.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] EXCEPTION {e}\n")

class H(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"

    def send_bytes(self,code,raw,ctype="application/json; charset=utf-8"):
        if isinstance(raw,str):raw=raw.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type",ctype)
        self.send_header("Cache-Control","no-store")
        self.send_header("Content-Length",str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def send_json(self,code,obj):
        self.send_bytes(code,json.dumps(obj,ensure_ascii=False).encode("utf-8"))

    def do_GET(self):
        p=urlparse(self.path).path
        if p=="/api/health":
            return self.send_json(200,{"ok":True,"service":"central-auditor-ui","port":PORT})
        if p=="/api/runs":
            rows=load_runs()
            slim=[]
            for r in rows[:50]:
                slim.append({k:r.get(k) for k in ("id","filename","kind","status","created_at","started_at","finished_at","project_id","size")})
            return self.send_json(200,{"ok":True,"runs":slim})
        m=re.fullmatch(r"/api/runs/([A-Za-z0-9_-]+)",p)
        if m:
            r=get_run(m.group(1))
            if not r:return self.send_json(404,{"ok":False,"error":"RUN_NOT_FOUND"})
            return self.send_json(200,{"ok":True,"run":r})
        m=re.fullmatch(r"/api/runs/([A-Za-z0-9_-]+)/log",p)
        if m:
            rid=m.group(1); r=get_run(rid)
            if not r:return self.send_json(404,{"ok":False,"error":"RUN_NOT_FOUND"})
            lp=LOGS/f"{rid}.log"
            txt=lp.read_text(encoding="utf-8",errors="replace")[-200000:] if lp.is_file() else ""
            return self.send_bytes(200,txt,"text/plain; charset=utf-8")
        if p in ("/","/index.html"):
            return self.send_bytes(200,INDEX,"text/html; charset=utf-8")
        return self.send_json(404,{"ok":False,"error":"NOT_FOUND"})

    def do_POST(self):
        p=urlparse(self.path).path
        if p!="/api/upload":
            return self.send_json(404,{"ok":False,"error":"NOT_FOUND"})
        try:
            n=int(self.headers.get("Content-Length","0") or 0)
        except Exception:
            n=0
        if n<=0:return self.send_json(400,{"ok":False,"error":"EMPTY_UPLOAD"})
        if n>MAX_UPLOAD:return self.send_json(413,{"ok":False,"error":"UPLOAD_TOO_LARGE","max_bytes":MAX_UPLOAD})

        filename=safe_filename(self.headers.get("X-Filename") or "app.apk")
        kind=(self.headers.get("X-Kind") or "").lower().strip()
        if kind not in ("apk","xapk"):
            kind="xapk" if filename.lower().endswith(".xapk") else "apk"

        rid="AU-"+time.strftime("%Y%m%d-%H%M%S")+"-"+uuid.uuid4().hex[:6]
        dest=INBOX/f"{rid}-{filename}"
        remaining=n
        with dest.open("wb") as f:
            while remaining>0:
                chunk=self.rfile.read(min(1024*1024,remaining))
                if not chunk:break
                f.write(chunk); remaining-=len(chunk)
        actual=dest.stat().st_size if dest.exists() else 0
        if actual!=n:
            dest.unlink(missing_ok=True)
            return self.send_json(400,{"ok":False,"error":"INCOMPLETE_UPLOAD","expected":n,"actual":actual})

        row={
            "id":rid,"filename":filename,"kind":kind,"status":"QUEUED",
            "created_at":now(),"size":actual,"source_path":str(dest),"project_id":None
        }
        with LOCK:
            rows=load_runs(); rows.insert(0,row); save_runs(rows[:100])

        t=threading.Thread(target=worker,args=(rid,dest,kind,filename),daemon=True)
        t.start()
        return self.send_json(202,{"ok":True,"run_id":rid,"status":"QUEUED","filename":filename,"size":actual})

    def log_message(self,fmt,*args):
        pass

INDEX=r'''<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Central · Auditor</title>
<style>
:root{color-scheme:dark;--bg:#0d0f13;--panel:#151922;--panel2:#1c2230;--line:#2c3444;--text:#f2f5f8;--muted:#98a4b5;--ok:#76d49b;--warn:#f2c96d;--err:#ef7f7f}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
.wrap{max-width:980px;margin:auto;padding:18px 14px 40px}.top{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:18px}
h1{font-size:22px;margin:0}.sub{font-size:13px;color:var(--muted);margin-top:4px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:16px;margin-bottom:14px}
.drop{border:1px dashed #46536b;border-radius:14px;padding:26px 16px;text-align:center;background:#11151c}
input[type=file]{width:100%;margin-top:14px}.btn{border:0;border-radius:12px;padding:12px 16px;font-weight:700;background:#edf2f7;color:#111;cursor:pointer}
.btn:disabled{opacity:.45}.meta{margin-top:10px;font-size:13px;color:var(--muted)}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:14px}.status{font-weight:700}.ok{color:var(--ok)}.err{color:var(--err)}.running{color:var(--warn)}
pre{white-space:pre-wrap;word-break:break-word;max-height:420px;overflow:auto;background:#090b0f;border-radius:12px;padding:12px;font-size:12px;line-height:1.45}
.run{padding:12px 0;border-top:1px solid var(--line);display:flex;justify-content:space-between;gap:12px}.run:first-child{border-top:0}.run small{color:var(--muted)}
.badge{font-size:11px;padding:4px 8px;border:1px solid var(--line);border-radius:999px;height:max-content}
@media(max-width:700px){.grid{grid-template-columns:1fr}.wrap{padding:12px 10px 30px}.card{padding:13px}pre{max-height:360px}}
</style>
</head>
<body>
<div class="wrap">
  <div class="top"><div><h1>Auditor</h1><div class="sub">Central · APK / XAPK · análisis y desofuscación automáticos</div></div><div class="badge" id="health">comprobando…</div></div>

  <div class="card">
    <div class="drop">
      <strong>Seleccioná una aplicación</strong>
      <div class="sub">Se guarda la entrada, corre el pipeline completo y se registran los logs automáticamente.</div>
      <input id="file" type="file" accept=".apk,.xapk,application/vnd.android.package-archive">
      <div class="meta" id="filemeta">APK o XAPK</div>
      <div style="margin-top:14px"><button class="btn" id="go" disabled>Analizar</button></div>
    </div>
  </div>

  <div class="grid">
    <div class="card">
      <div class="status" id="state">Sin análisis activo</div>
      <div class="meta" id="detail">—</div>
    </div>
    <div class="card">
      <strong>Proyecto</strong>
      <div class="meta" id="project">Todavía no generado</div>
    </div>
  </div>

  <div class="card">
    <strong>Log en vivo</strong>
    <pre id="log">Esperando un análisis…</pre>
  </div>

  <div class="card">
    <strong>Últimos análisis</strong>
    <div id="runs" class="meta">Cargando…</div>
  </div>
</div>
<script>
const $=s=>document.querySelector(s)
let active=null,timer=null
function fmtBytes(n){if(!n)return '0 B';const u=['B','KB','MB','GB'];let i=0,v=n;while(v>=1024&&i<u.length-1){v/=1024;i++}return v.toFixed(i?1:0)+' '+u[i]}
function fmtTime(t){return t?new Date(t*1000).toLocaleString():'—'}
async function api(u,o){const r=await fetch(u,o);let j;try{j=await r.json()}catch{j={}}if(!r.ok)throw new Error(j.error||r.status);return j}
async function health(){try{await api('api/health');$('#health').textContent='online';$('#health').className='badge ok'}catch{$('#health').textContent='offline';$('#health').className='badge err'}}
$('#file').onchange=()=>{const f=$('#file').files[0];$('#go').disabled=!f;$('#filemeta').textContent=f?f.name+' · '+fmtBytes(f.size):'APK o XAPK'}
$('#go').onclick=async()=>{
 const f=$('#file').files[0];if(!f)return
 $('#go').disabled=true;$('#state').textContent='Subiendo…';$('#state').className='status running';$('#detail').textContent=f.name+' · '+fmtBytes(f.size)
 try{
   const kind=f.name.toLowerCase().endsWith('.xapk')?'xapk':'apk'
   const r=await fetch('api/upload',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Filename':encodeURIComponent(f.name),'X-Kind':kind},body:f})
   const j=await r.json();if(!r.ok)throw new Error(j.error||r.status)
   active=j.run_id;watch();loadRuns()
 }catch(e){$('#state').textContent='Error';$('#state').className='status err';$('#detail').textContent=e.message;$('#go').disabled=false}
}
async function watch(){
 if(!active)return
 clearTimeout(timer)
 try{
   const x=await api('api/runs/'+active);const r=x.run
   $('#state').textContent=r.status||'—'
   $('#state').className='status '+(r.status==='COMPLETED'?'ok':r.status==='ERROR'?'err':'running')
   $('#detail').textContent=r.filename+' · '+fmtBytes(r.size)+' · '+fmtTime(r.started_at||r.created_at)
   $('#project').textContent=r.project_id||'Esperando al pipeline…'
   try{const lr=await fetch('api/runs/'+active+'/log');$('#log').textContent=await lr.text();$('#log').scrollTop=$('#log').scrollHeight}catch{}
   if(r.status==='COMPLETED'||r.status==='ERROR'){$('#go').disabled=false;loadRuns();return}
 }catch(e){$('#detail').textContent=e.message}
 timer=setTimeout(watch,1500)
}
async function loadRuns(){
 try{
  const x=await api('api/runs');const box=$('#runs');box.innerHTML=''
  if(!x.runs.length){box.textContent='Todavía no hay análisis.';return}
  for(const r of x.runs){
   const d=document.createElement('div');d.className='run'
   const l=document.createElement('div');l.innerHTML='<div>'+r.filename+'</div><small>'+fmtTime(r.created_at)+(r.project_id?' · '+r.project_id:'')+'</small>'
   const b=document.createElement('button');b.className='badge';b.textContent=r.status||'—';b.onclick=()=>{active=r.id;watch()}
   d.append(l,b);box.appendChild(d)
  }
 }catch(e){$('#runs').textContent='Error: '+e.message}
}
health();loadRuns()
</script>
</body></html>'''

if __name__=="__main__":
    ThreadingHTTPServer((HOST,PORT),H).serve_forever()
PY

chmod 755 "$APP/server.py"
chown -R ubuntu:ubuntu "$APP" /home/ubuntu/Central/inbox /home/ubuntu/Central/logs/auditor
python3 -m py_compile "$APP/server.py"
echo AUDITOR_UI_SOURCE_OK

echo "=== 2. INSTALL SYSTEMD SERVICE ==="
cat >"$SERVICE" <<'UNIT'
[Unit]
Description=Central Auditor UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/home/ubuntu/Central/auditor_ui_v1
ExecStart=/usr/bin/python3 /home/ubuntu/Central/auditor_ui_v1/server.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now central-auditor-ui.service
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:$PORT/api/health >/tmp/auditor-ui-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/auditor-ui-health.json
echo
systemctl is-active central-auditor-ui.service
echo AUDITOR_UI_SERVICE_OK

echo "=== 3. INSTALL CADDY ROUTE ==="
if ! grep -q 'route /auditor/\*' "$CADDY"; then
python3 - <<'PY'
from pathlib import Path
p=Path("/etc/caddy/Caddyfile")
s=p.read_text(encoding="utf-8")
block='''    route /auditor {
        redir /auditor/ 308
    }

    route /auditor/* {
        uri strip_prefix /auditor
        reverse_proxy 127.0.0.1:8792
    }

'''
anchors=[
    '    route /interfaz {\n',
    '    route /interfaz/* {\n',
    '    route {\n'
]
for a in anchors:
    if a in s:
        s=s.replace(a,block+a,1)
        break
else:
    pos=s.rfind('}')
    if pos<0: raise SystemExit("CADDY_SITE_BLOCK_NOT_FOUND")
    s=s[:pos]+block+s[pos:]
p.write_text(s,encoding="utf-8")
PY
fi
caddy validate --config "$CADDY"
systemctl reload caddy
echo AUDITOR_UI_CADDY_OK

echo "=== 4. VERIFY LOCAL UI + LOG API ==="
HTML=$(curl -fsS --max-time 10 http://127.0.0.1:$PORT/)
grep -q 'Central · APK / XAPK' <<<"$HTML"
grep -q 'Log en vivo' <<<"$HTML"
RUNS=$(curl -fsS --max-time 10 http://127.0.0.1:$PORT/api/runs)
RUNS_JSON="$RUNS" python3 - <<'PY'
import json,os
x=json.loads(os.environ["RUNS_JSON"])
assert x["ok"] is True,x
assert isinstance(x["runs"],list),x
print("AUDITOR_UI_API_OK")
PY
echo AUDITOR_UI_LOCAL_OK

echo "=== 5. VERIFY PUBLIC HTTPS ==="
PUB=$(curl -fsS --max-time 20 https://cen-tral.duckdns.org/auditor/)
grep -q 'Central · APK / XAPK' <<<"$PUB"
curl -fsS --max-time 20 https://cen-tral.duckdns.org/auditor/api/health | grep -q '"ok": true'
echo AUDITOR_UI_PUBLIC_OK

echo "=== 6. VERIFY AUTOMATIC LOG DIRECTORIES ==="
test -d /home/ubuntu/Central/logs/auditor
test -w /home/ubuntu/Central/logs/auditor
test -d /home/ubuntu/Central/inbox
test -w /home/ubuntu/Central/inbox
echo AUDITOR_AUTO_LOGS_READY

echo CENTRAL_AUDITOR_UI_V1_READY
echo "URL=https://cen-tral.duckdns.org/auditor/"
echo "logs=/home/ubuntu/Central/logs/auditor"
echo "backup=$BACKUP"
