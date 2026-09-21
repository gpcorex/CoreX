#!/usr/bin/env bash
set -euo pipefail

MAIN=/home/ubuntu/Gemini/app/main.py
UI=/home/ubuntu/Gemini/web/index.html
BACKUP=/home/ubuntu/Gemini/backups/connect-central-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP"
cp -a "$MAIN" "$BACKUP/main.py"
cp -a "$UI" "$BACKUP/index.html"

python3 - <<'PY'
from pathlib import Path

p = Path("/home/ubuntu/Gemini/app/main.py")
s = p.read_text(encoding="utf-8")

if "import urllib.request" not in s:
    s = s.replace("import json", "import json\nimport urllib.request\nimport urllib.error", 1)

helper = r'''
CENTRAL_JOBS_BASE = "http://127.0.0.1:8091"

def _looks_like_programming_request(message: str) -> bool:
    m = (message or "").lower()
    verbs = (
        "creá", "crea ", "crear ", "modificá", "modifica ", "modificar ",
        "editá", "edita ", "editar ", "corregí", "corrige ", "corregir ",
        "arreglá", "arregla ", "arreglar ", "implementá", "implementa ",
        "implementar ", "instalá", "instala ", "instalar ", "programá",
        "programa ", "programar ", "agregá", "agrega ", "añadí", "reemplazá",
        "reemplaza ", "actualizá", "actualiza ", "desplegá", "despliega ",
        "reiniciá", "reinicia ", "reiniciar ", "configurá", "configura ",
        "configurar ", "creame ", "hacé ", "hace ", "hacer "
    )
    targets = (
        "/home/", "/srv/", "/opt/", "/tmp/", ".py", ".js", ".json", ".html",
        ".css", ".service", ".sh", "archivo", "carpeta", "código", "codigo",
        "script", "backend", "frontend", "servidor", "vm", "servicio",
        "proyecto", "app", "aplicación", "aplicacion", "endpoint", "api",
        "base de datos", "sqlite", "caddy", "openclaw", "central", "gemini"
    )
    return any(v in m for v in verbs) and any(t in m for t in targets)

def _central_request(method: str, path: str, payload=None, timeout=8):
    url = CENTRAL_JOBS_BASE + path
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8", errors="replace")
            return r.status, json.loads(raw or "{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            body = json.loads(raw or "{}")
        except Exception:
            body = {"error": raw}
        return e.code, body

async def _run_central_job(message: str, conversation_id: str):
    import asyncio
    code, body = await asyncio.to_thread(
        _central_request,
        "POST",
        "/api/jobs",
        {
            "source": "gemini",
            "project": "Gemini",
            "conversation_id": conversation_id,
            "task": message,
        },
        8,
    )
    if code != 202 or not body.get("job_id"):
        raise RuntimeError("Central no aceptó el trabajo: " + json.dumps(body, ensure_ascii=False))

    job_id = body["job_id"]
    deadline = time.time() + 390
    last = {"status": body.get("status", "RECIBIDA")}

    while time.time() < deadline:
        await asyncio.sleep(2)
        code, current = await asyncio.to_thread(
            _central_request,
            "GET",
            f"/api/jobs/{job_id}",
            None,
            8,
        )
        if code != 200:
            continue
        job = current.get("job") or {}
        last = job
        if job.get("status") in ("COMPLETADA", "ERROR"):
            return job
    raise RuntimeError(f"Central agotó el tiempo para {job_id}; último estado={last.get('status')}")
'''

if "CENTRAL_JOBS_BASE = " not in s:
    marker = '@app.post("/api/chat/direct")'
    if marker not in s:
        raise SystemExit("DIRECT_ROUTE_MARKER_NOT_FOUND")
    s = s.replace(marker, helper + "\n\n" + marker, 1)

route_marker = '@app.post("/api/chat/direct")'
idx = s.find(route_marker)
if idx < 0:
    raise SystemExit("DIRECT_ROUTE_NOT_FOUND")

func_start = s.find("async def ", idx)
if func_start < 0:
    raise SystemExit("DIRECT_FUNC_NOT_FOUND")
body_start = s.find("\n", func_start) + 1

if "_looks_like_programming_request(message)" not in s[idx:idx+20000]:
    injection = r'''
    # Órdenes operativas/programación: Central gobierna, OpenClaw ejecuta.
    if _looks_like_programming_request(message):
        job = await _run_central_job(message, cid)
        status = job.get("status")
        raw_result = job.get("result")
        if isinstance(raw_result, dict):
            answer = str(
                raw_result.get("final")
                or raw_result.get("answer")
                or raw_result.get("result")
                or json.dumps(raw_result, ensure_ascii=False)
            )
        else:
            answer = str(raw_result or job.get("error") or "Trabajo finalizado sin detalle.")

        if status != "COMPLETADA":
            answer = f"Central terminó con estado {status}: {answer}"

        now2 = int(time.time())
        with db() as c:
            c.execute(
                """
                INSERT INTO messages
                (conversation_id, role, content, provider, model, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (cid, "assistant", answer, "central", "openclaw", now2),
            )
            c.execute(
                "UPDATE conversations SET updated_at=? WHERE id=?",
                (now2, cid),
            )

        return {
            "ok": status == "COMPLETADA",
            "conversation_id": cid,
            "execution_mode": "central_job",
            "brain": "gemini",
            "provider": "central",
            "model": "openclaw",
            "answer": answer,
            "job": job,
            "files": [],
        }

'''
    # place after cid/message/file_ids initialization by finding file_ids line block end
    window = s[body_start:body_start+6000]
    anchor = "    previous_history = _direct_history(cid)"
    rel = window.find(anchor)
    if rel < 0:
        anchor = "    history = _direct_history(cid)"
        rel = window.find(anchor)
    if rel < 0:
        raise SystemExit("DIRECT_HISTORY_ANCHOR_NOT_FOUND")
    abspos = body_start + rel
    s = s[:abspos] + injection + s[abspos:]

p.write_text(s, encoding="utf-8")
print("MAIN_PATCH_OK")
PY

python3 -m py_compile "$MAIN"

sudo systemctl restart gemini-backend.service

for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/gem-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done

echo "=== GEMINI HEALTH ==="
cat /tmp/gem-health.json

echo
echo "=== CENTRAL JOBS HEALTH ==="
curl -fsS --max-time 3 http://127.0.0.1:8091/api/health

echo
echo "=== END-TO-END WRITE TEST ==="
RESP=$(curl -sS --max-time 420   -H 'Content-Type: application/json'   -d '{"message":"Creá /tmp/gemini-central-e2e.txt con el texto GEMINI_CENTRAL_E2E_OK","conversation_id":"central-e2e-test"}'   http://127.0.0.1:8791/api/chat/direct)
printf '%s\n' "$RESP"

echo
echo "=== FILE VERIFY ==="
cat /tmp/gemini-central-e2e.txt

echo
echo GEMINI_CENTRAL_LINK_READY
