#!/usr/bin/env bash
set -euo pipefail

APP=/home/ubuntu/Central/runtime/jobs_api.py
STATE=/home/ubuntu/Central/data/api-jobs
SERVICE=/etc/systemd/system/central-jobs-api.service

mkdir -p "$(dirname "$APP")" "$STATE" /home/ubuntu/Central/work

cat >"$APP" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import json, os, subprocess, threading, time, uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

HOST="127.0.0.1"
PORT=8091
EXECUTOR=Path("/home/ubuntu/Central/runtime/executor.js")
STATE=Path("/home/ubuntu/Central/data/api-jobs")
WORKROOT=Path("/home/ubuntu/Central/work")
NODE="/usr/bin/node"

STATE.mkdir(parents=True, exist_ok=True)
WORKROOT.mkdir(parents=True, exist_ok=True)

def now():
    return int(time.time())

def write_json(path: Path, data: dict):
    tmp=path.with_suffix(path.suffix+".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    tmp.replace(path)

def load_job(job_id: str):
    p=STATE/job_id/"job.json"
    if not p.is_file():
        return None
    return json.loads(p.read_text(encoding="utf-8"))

def save_job(job: dict):
    d=STATE/job["id"]
    d.mkdir(parents=True, exist_ok=True)
    write_json(d/"job.json", job)

def run_job(job_id: str):
    job=load_job(job_id)
    if not job:
        return
    job["status"]="EJECUTANDO"
    job["started_at"]=now()
    save_job(job)

    d=STATE/job_id
    workspace=WORKROOT/job_id
    workspace.mkdir(parents=True, exist_ok=True)
    payload={
        "id":"TASK-EXEC-NICO-001",
        "trabajo":job_id,
        "jugador":"Nico González",
        "objetivo":job["task"],
        "base":"/home/ubuntu",
        "workspace":str(workspace),
        "tarea":job["task"],
        "restricciones":[
            "Usar el estado real de la VM.",
            "No rediseñar arquitectura salvo necesidad demostrada.",
            "Verificar el cambio antes de declarar completado."
        ],
        "contexto":{
            "source":job.get("source","gemini"),
            "project":job.get("project",""),
            "conversation_id":job.get("conversation_id","")
        },
        "criterio_exito":"La tarea queda ejecutada y verificada; la salida final incluye CENTRAL_STATUS=COMPLETADO.",
        "timeout":330
    }
    task_path=d/"task.json"
    write_json(task_path,payload)

    try:
        cp=subprocess.run(
            [NODE, str(EXECUTOR), str(task_path)],
            cwd="/home/ubuntu/Central",
            capture_output=True, text=True, timeout=360
        )
        (d/"stdout.txt").write_text(cp.stdout or "", encoding="utf-8")
        (d/"stderr.txt").write_text(cp.stderr or "", encoding="utf-8")

        job=load_job(job_id) or job
        job["status"]="PROBANDO"
        save_job(job)

        raw=(cp.stdout or "").strip()
        parsed=None
        try:
            parsed=json.loads(raw) if raw else None
        except Exception:
            parsed=None

        text = ""
        if isinstance(parsed, dict):
            text = str(parsed.get("final") or parsed.get("answer") or parsed.get("result") or raw)
        else:
            text = raw

        ok=(cp.returncode==0 and "CENTRAL_STATUS=COMPLETADO" in text)
        job=load_job(job_id) or job
        job["returncode"]=cp.returncode
        job["result"]=parsed if parsed is not None else raw
        job["stderr_tail"]=(cp.stderr or "")[-4000:]
        job["finished_at"]=now()
        job["status"]="COMPLETADA" if ok else "ERROR"
        save_job(job)
    except Exception as e:
        job=load_job(job_id) or job
        job["status"]="ERROR"
        job["error"]=str(e)
        job["finished_at"]=now()
        save_job(job)

class H(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        raw=json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type","application/json; charset=utf-8")
        self.send_header("Cache-Control","no-store")
        self.send_header("Content-Length",str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        p=urlparse(self.path).path
        if p=="/api/health":
            return self._json(200,{"ok":True,"service":"central-jobs-api"})
        if p.startswith("/api/jobs/"):
            job_id=p.rsplit("/",1)[-1]
            job=load_job(job_id)
            if not job:
                return self._json(404,{"ok":False,"error":"JOB_NOT_FOUND"})
            return self._json(200,{"ok":True,"job":job})
        return self._json(404,{"ok":False,"error":"NOT_FOUND"})

    def do_POST(self):
        p=urlparse(self.path).path
        if p!="/api/jobs":
            return self._json(404,{"ok":False,"error":"NOT_FOUND"})
        try:
            n=int(self.headers.get("Content-Length","0") or "0")
            body=json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._json(400,{"ok":False,"error":"INVALID_JSON"})

        task=str(body.get("task") or "").strip()
        if not task:
            return self._json(400,{"ok":False,"error":"TASK_REQUIRED"})

        job_id="TR-GEMINI-"+time.strftime("%Y%m%d-%H%M%S")+"-"+uuid.uuid4().hex[:6]
        job={
            "id":job_id,
            "status":"RECIBIDA",
            "created_at":now(),
            "source":str(body.get("source") or "gemini"),
            "project":str(body.get("project") or ""),
            "conversation_id":str(body.get("conversation_id") or ""),
            "task":task,
        }
        save_job(job)
        threading.Thread(target=run_job,args=(job_id,),daemon=True).start()
        return self._json(202,{"ok":True,"job_id":job_id,"status":"RECIBIDA"})

    def log_message(self, fmt, *args):
        pass

if __name__=="__main__":
    ThreadingHTTPServer((HOST,PORT),H).serve_forever()
PY

chmod 755 "$APP"

cat >"$SERVICE" <<'EOF'
[Unit]
Description=Central local jobs API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/home/ubuntu/Central
ExecStart=/usr/bin/python3 /home/ubuntu/Central/runtime/jobs_api.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now central-jobs-api.service

for i in $(seq 1 20); do
  if curl -fsS --max-time 2 http://127.0.0.1:8091/api/health >/tmp/central-jobs-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done

cat /tmp/central-jobs-health.json
echo
echo CENTRAL_JOBS_API_READY
