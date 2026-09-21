#!/usr/bin/env bash
set -euo pipefail

OUT=/var/lib/conector/gemini-urgent-repair.txt
mkdir -p /var/lib/conector

log(){ echo "[$(date -Is)] $*"; }

{
  echo "GEMINI_URGENT_REPAIR"
  echo "generated_at=$(date -Is)"
  echo "host=$(hostname)"
  echo

  MAIN=/home/ubuntu/Gemini/app/main.py
  BRIDGE=/home/ubuntu/Gemini/app/central_executor_bridge.py

  echo "[PRECHECK]"
  systemctl is-active gemini-backend.service || true
  curl -sS -o /tmp/gem-health-pre -w 'health_http=%{http_code}\n' --max-time 5 http://127.0.0.1:8791/api/health || true
  cat /tmp/gem-health-pre 2>/dev/null || true
  echo

  echo "[BACKUP]"
  cp -a "$MAIN" "$MAIN.before-urgent-repair-$(date +%Y%m%d-%H%M%S)"
  echo backup_ok
  echo

  echo "[PATCH]"
  python3 - <<'PY'
from pathlib import Path
p=Path('/home/ubuntu/Gemini/app/main.py')
s=p.read_text(encoding='utf-8')

# Add a dedicated, narrow write endpoint instead of risking normal chat.
marker='@app.post("/api/chat/direct")'
if marker not in s:
    raise SystemExit('DIRECT_MARKER_NOT_FOUND')

route=r'''
@app.post("/api/chat/write")
async def chat_write(body: ChatInput):
    message = (body.message or "").strip()
    if not message:
        raise HTTPException(status_code=400, detail="Mensaje vacío")

    cid = body.conversation_id or str(uuid.uuid4())
    now = int(time.time())

    with db() as c:
        row = c.execute(
            "SELECT id FROM conversations WHERE id=?",
            (cid,),
        ).fetchone()
        if row is None:
            c.execute(
                "INSERT INTO conversations (id,title,created_at,updated_at) VALUES (?,?,?,?)",
                (cid, message[:80] or "Nueva conversación", now, now),
            )
        c.execute(
            "INSERT INTO messages (conversation_id,role,content,provider,model,created_at) VALUES (?,?,?,?,?,?)",
            (cid, "user", message, "user", None, now),
        )

    from central_executor_bridge import execute_write

    try:
        execution = await execute_write(
            task=message,
            original_message=message,
            brain="gemini",
        )
    except Exception as exc:
        execution = {"ok": False, "error": str(exc)}

    ok = bool(execution.get("ok"))
    answer = (
        execution.get("answer")
        or execution.get("final")
        or execution.get("result")
        or execution.get("message")
        or execution.get("error")
        or ("Tarea ejecutada." if ok else "La ejecución no pudo completarse.")
    )
    if not isinstance(answer, str):
        answer = json.dumps(answer, ensure_ascii=False)

    now2 = int(time.time())
    with db() as c:
        c.execute(
            "INSERT INTO messages (conversation_id,role,content,provider,model,created_at) VALUES (?,?,?,?,?,?)",
            (cid, "assistant", answer, "central", "nico-openclaw", now2),
        )
        c.execute(
            "UPDATE conversations SET updated_at=? WHERE id=?",
            (now2, cid),
        )

    return {
        "ok": ok,
        "conversation_id": cid,
        "execution_mode": "central_write",
        "brain": "gemini",
        "provider": "central",
        "model": "nico-openclaw",
        "answer": answer,
        "execution": execution,
    }

'''

if '@app.post("/api/chat/write")' not in s:
    s=s.replace(marker, route+marker, 1)

p.write_text(s, encoding='utf-8')
print('WRITE_ROUTE_READY')
PY

  python3 -m py_compile "$MAIN"
  echo compile_ok
  echo

  echo "[RESTART]"
  systemctl restart gemini-backend.service
  for i in $(seq 1 20); do
    if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/gem-health-post 2>/dev/null; then
      break
    fi
    sleep 1
  done
  systemctl is-active gemini-backend.service
  cat /tmp/gem-health-post 2>/dev/null || true
  echo

  echo "[WRITE_ENDPOINT_TEST]"
  RESP=$(curl -sS --max-time 180 -w '\nHTTP_STATUS=%{http_code}\n'     -H 'Content-Type: application/json'     -d '{"message":"Creá /tmp/gemini-urgent-write.txt con el texto GEMINI_URGENT_WRITE_OK","conversation_id":"urgent-repair-test"}'     http://127.0.0.1:8791/api/chat/write || true)
  printf '%s\n' "$RESP"
  echo

  echo "[FILE_TEST]"
  ls -l /tmp/gemini-urgent-write.txt 2>&1 || true
  cat /tmp/gemini-urgent-write.txt 2>&1 || true
  echo

  echo "[RECENT_LOGS]"
  journalctl -u gemini-backend.service -n 120 --no-pager 2>&1 || true

} >"$OUT" 2>&1

if [ -x /usr/local/sbin/conector-publish-result ]; then
  /usr/local/sbin/conector-publish-result "$OUT" "vm-results/gemini-urgent-repair.txt" || true
fi

# Also expose through existing CoreX result web directory for redundancy.
mkdir -p /srv/apps/android-bridge/www/corex-results
cp -f "$OUT" /srv/apps/android-bridge/www/corex-results/gemini-urgent-repair.txt || true
chmod 644 /srv/apps/android-bridge/www/corex-results/gemini-urgent-repair.txt || true

echo GEMINI_URGENT_REPAIR_DONE
