#!/usr/bin/env bash
set -euo pipefail
MAIN=/home/ubuntu/Gemini/app/main.py
JOBS=/home/ubuntu/Central/runtime/jobs_api.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/native-programmer-$STAMP
mkdir -p "$BACKUP"
cp -a "$MAIN" "$BACKUP/main.py"
cp -a "$JOBS" "$BACKUP/jobs_api.py"

python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/runtime/jobs_api.py")
s=p.read_text(encoding="utf-8")
if "NATIVE_PROGRAMMER_TOOL_API" not in s:
    anchor="class H(BaseHTTPRequestHandler):\n"
    pos=s.find(anchor)
    if pos<0:
        raise SystemExit("HANDLER_NOT_FOUND")
    helper=r'''
# NATIVE_PROGRAMMER_TOOL_API
SAFE_ROOTS=[Path("/home/ubuntu"),Path("/srv/apps"),Path("/opt/corex/repo"),Path("/tmp")]
SAFE_BINARIES={"python3","python","node","npm","npx","git","grep","find","ls","cat","head","tail","sed","mkdir","cp","mv","chmod","stat","wc","sort","cut","awk","tee","printf","echo","curl"}

def _safe_path(raw):
    if not raw:
        raise ValueError("PATH_REQUIRED")
    path=Path(raw).expanduser()
    if not path.is_absolute():
        path=Path("/home/ubuntu")/path
    resolved=path.resolve()
    for root in SAFE_ROOTS:
        rr=root.resolve()
        if resolved==rr or rr in resolved.parents:
            return resolved
    raise ValueError("PATH_OUTSIDE_ALLOWED_ROOTS")

def _agent_action(body):
    action=str(body.get("action") or "").strip()
    if action=="read_file":
        path=_safe_path(str(body.get("path") or ""))
        if not path.is_file():
            return {"ok":False,"error":"FILE_NOT_FOUND","path":str(path)}
        raw=path.read_text(encoding="utf-8",errors="replace")
        return {"ok":True,"action":action,"path":str(path),"content":raw[:120000],"truncated":len(raw)>120000}
    if action=="list_dir":
        path=_safe_path(str(body.get("path") or "/home/ubuntu"))
        if not path.is_dir():
            return {"ok":False,"error":"DIR_NOT_FOUND","path":str(path)}
        items=[]
        for child in sorted(path.iterdir(),key=lambda x:x.name.lower())[:500]:
            try:
                st=child.stat()
                items.append({"name":child.name,"path":str(child),"type":"dir" if child.is_dir() else "file","size":st.st_size})
            except Exception:
                pass
        return {"ok":True,"action":action,"path":str(path),"items":items}
    if action=="write_file":
        path=_safe_path(str(body.get("path") or ""))
        content=body.get("content")
        if not isinstance(content,str):
            raise ValueError("CONTENT_STRING_REQUIRED")
        if len(content.encode("utf-8"))>2000000:
            raise ValueError("CONTENT_TOO_LARGE")
        path.parent.mkdir(parents=True,exist_ok=True)
        backup=None
        if path.exists() and path.is_file():
            backup=path.with_name(path.name+f".centralbak-{int(time.time())}")
            backup.write_bytes(path.read_bytes())
        path.write_text(content,encoding="utf-8")
        verified=path.read_text(encoding="utf-8")==content
        return {"ok":verified,"action":action,"path":str(path),"backup":str(backup) if backup else None,"verified":verified}
    if action=="run":
        argv=body.get("argv")
        if not isinstance(argv,list) or not argv or not all(isinstance(x,str) for x in argv):
            raise ValueError("ARGV_STRING_LIST_REQUIRED")
        binary=Path(argv[0]).name
        if binary not in SAFE_BINARIES:
            raise ValueError("BINARY_NOT_ALLOWED:"+binary)
        cwd=_safe_path(str(body.get("cwd") or "/home/ubuntu"))
        timeout=max(1,min(int(body.get("timeout") or 60),120))
        cp=subprocess.run(argv,cwd=str(cwd),capture_output=True,text=True,timeout=timeout,env={**os.environ,"HOME":"/home/ubuntu"})
        return {"ok":cp.returncode==0,"action":action,"argv":argv,"cwd":str(cwd),"returncode":cp.returncode,"stdout":(cp.stdout or "")[-30000:],"stderr":(cp.stderr or "")[-30000:]}
    raise ValueError("UNKNOWN_ACTION:"+action)

'''
    s=s[:pos]+helper+s[pos:]
    old='''    def do_POST(self):
        p=urlparse(self.path).path
        if p!="/api/jobs":
            return self._json(404,{"ok":False,"error":"NOT_FOUND"})
'''
    new='''    def do_POST(self):
        p=urlparse(self.path).path
        if p=="/api/agent/action":
            try:
                n=int(self.headers.get("Content-Length","0") or "0")
                body=json.loads(self.rfile.read(n) or b"{}")
                return self._json(200,_agent_action(body))
            except subprocess.TimeoutExpired:
                return self._json(408,{"ok":False,"error":"ACTION_TIMEOUT"})
            except Exception as e:
                return self._json(400,{"ok":False,"error":str(e)})
        if p!="/api/jobs":
            return self._json(404,{"ok":False,"error":"NOT_FOUND"})
'''
    if old not in s:
        raise SystemExit("POST_ANCHOR_NOT_FOUND")
    s=s.replace(old,new,1)
    p.write_text(s,encoding="utf-8")
    print("CENTRAL_TOOL_API_ADDED")
else:
    print("CENTRAL_TOOL_API_PRESENT")
PY

python3 -m py_compile "$JOBS"
systemctl restart central-jobs-api.service

python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")
if "NATIVE_PROGRAMMER_V1" not in s:
    anchor='CENTRAL_JOBS_BASE = "http://127.0.0.1:8091"\n'
    apos=s.find(anchor)
    if apos<0:
        raise SystemExit("CENTRAL_BASE_NOT_FOUND")
    helper=r'''

# NATIVE_PROGRAMMER_V1
NATIVE_PROGRAMMER_MAX_STEPS=12

def _extract_json_object(text):
    import json as _json
    raw=(text or "").strip()
    try:
        return _json.loads(raw)
    except Exception:
        a=raw.find("{")
        b=raw.rfind("}")
        if a>=0 and b>a:
            return _json.loads(raw[a:b+1])
        raise

async def _central_agent_action(action):
    import asyncio
    return await asyncio.to_thread(_central_request,"POST","/api/agent/action",action,130)

async def _run_native_programmer(task,conversation_id):
    system="""Sos el programador operativo de Central. Inspeccioná, modificá y probá la VM usando solo acciones JSON. No expliques planes: ejecutá. No rediseñes la arquitectura si no hace falta. Antes de modificar un archivo existente, leelo. Después de modificar, verificá con una prueba concreta. No uses OpenClaw. No elijas provider: el Router externo ya lo hace. Respondé exclusivamente un objeto JSON.
Acciones:
{"action":"read_file","path":"/ruta"}
{"action":"list_dir","path":"/ruta"}
{"action":"write_file","path":"/ruta","content":"contenido completo"}
{"action":"run","argv":["python3","-m","py_compile","archivo.py"],"cwd":"/home/ubuntu","timeout":60}
{"action":"final","status":"COMPLETADO|ERROR","message":"resumen breve y verificable"}
Una sola acción por respuesta. No uses shell, pipes ni redirecciones. No borres archivos. Máximo 12 pasos."""
    messages=[{"role":"system","content":system},{"role":"user","content":task}]
    trace=[]
    last_provider=None
    last_model=None
    for step in range(1,NATIVE_PROGRAMMER_MAX_STEPS+1):
        answer,provider,model=await routed_answer(messages)
        last_provider=provider
        last_model=model
        try:
            obj=_extract_json_object(answer)
        except Exception:
            messages.append({"role":"assistant","content":answer})
            messages.append({"role":"user","content":"Respuesta inválida. Devolvé una sola acción JSON válida."})
            continue
        action=str(obj.get("action") or "").strip()
        if action=="final":
            status=str(obj.get("status") or "ERROR").upper()
            return {"ok":status=="COMPLETADO","status":status,"message":str(obj.get("message") or ""),"provider":provider,"model":model,"steps":step}
        if action not in {"read_file","list_dir","write_file","run"}:
            result={"ok":False,"error":"INVALID_ACTION","received":action}
        else:
            code,result=await _central_agent_action(obj)
            if code>=400 and isinstance(result,dict):
                result={**result,"http_status":code}
        trace.append({"step":step,"provider":provider,"model":model,"action":obj,"result":result})
        messages.append({"role":"assistant","content":json.dumps(obj,ensure_ascii=False)})
        messages.append({"role":"user","content":"TOOL_RESULT "+json.dumps(result,ensure_ascii=False)[:50000]})
    return {"ok":False,"status":"ERROR","message":"Máximo de pasos alcanzado.","provider":last_provider,"model":last_model,"steps":NATIVE_PROGRAMMER_MAX_STEPS}

'''
    s=s[:apos+len(anchor)]+helper+s[apos+len(anchor):]
    marker='''    # Órdenes operativas/programación: Central gobierna, OpenClaw ejecuta.
    if _looks_like_programming_request(message):
'''
    pos=s.find(marker)
    if pos<0:
        raise SystemExit("PROGRAMMING_BRANCH_NOT_FOUND")
    block='''    # Programación nativa: Router elige el modelo; Central ejecuta herramientas.
    if _looks_like_programming_request(message):
        result=await _run_native_programmer(message,cid)
        answer=result.get("message") or "Trabajo finalizado."
        now2=int(time.time())
        with db() as c:
            c.execute(
                "INSERT INTO messages (conversation_id, role, content, provider, model, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                (cid,"assistant",answer,"native-programmer",str(result.get("model") or ""),now2),
            )
            c.execute("UPDATE conversations SET updated_at=? WHERE id=?",(now2,cid))
        return {
            "ok":bool(result.get("ok")),
            "conversation_id":cid,
            "execution_mode":"native_programmer",
            "provider":result.get("provider"),
            "model":result.get("model"),
            "answer":answer,
            "steps":result.get("steps"),
            "files":[],
        }

'''
    s=s[:pos]+block+s[pos:]
    p.write_text(s,encoding="utf-8")
    print("NATIVE_PROGRAMMER_ADDED")
else:
    print("NATIVE_PROGRAMMER_PRESENT")
PY

python3 -m py_compile "$MAIN"
systemctl restart gemini-backend.service

for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/native-gemini-health.json 2>/dev/null && break
  sleep 1
done

echo "=== GEMINI ==="
cat /tmp/native-gemini-health.json
echo
echo "=== CENTRAL ==="
curl -fsS --max-time 3 http://127.0.0.1:8091/api/health
echo
echo "=== MARKERS ==="
grep -n 'NATIVE_PROGRAMMER_V1\|native_programmer' "$MAIN" | head -20
grep -n 'NATIVE_PROGRAMMER_TOOL_API\|api/agent/action' "$JOBS" | head -20
echo
echo GEMINI_NATIVE_PROGRAMMER_READY
