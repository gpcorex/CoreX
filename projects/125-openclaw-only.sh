#!/usr/bin/env bash
set -euo pipefail

OPENCLAW=/home/ubuntu/.npm-global/bin/openclaw
OCFG=/home/ubuntu/.openclaw/openclaw.json
OENV=/home/ubuntu/.openclaw/.env
OTOKEN=/home/ubuntu/.openclaw/gateway.token
MAIN=/home/ubuntu/Gemini/app/main.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/openclaw-only-$STAMP

mkdir -p "$BACKUP"
cp -a "$MAIN" "$BACKUP/main.py"
cp -a "$OCFG" "$BACKUP/openclaw.json" 2>/dev/null || true
cp -a "$OENV" "$BACKUP/openclaw.env" 2>/dev/null || true

test -x "$OPENCLAW" || { echo "OPENCLAW_NOT_FOUND"; exit 1; }

UBUNTU_UID="$(id -u ubuntu)"
OC() {
  runuser -u ubuntu -- env \
    HOME=/home/ubuntu \
    XDG_RUNTIME_DIR="/run/user/$UBUNTU_UID" \
    PATH="/home/ubuntu/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
    "$OPENCLAW" "$@"
}
USYSTEMCTL() {
  runuser -u ubuntu -- env \
    HOME=/home/ubuntu \
    XDG_RUNTIME_DIR="/run/user/$UBUNTU_UID" \
    PATH="/home/ubuntu/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
    systemctl --user "$@"
}

echo "=== 1. OPENCLAW OWNS PROVIDER CREDENTIALS ==="
python3 - <<'PY'
from pathlib import Path

env_path=Path("/home/ubuntu/.openclaw/.env")
env_path.parent.mkdir(parents=True,exist_ok=True)
existing={}
if env_path.exists():
    for line in env_path.read_text(encoding="utf-8",errors="replace").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k,v=line.split("=",1)
            existing[k.strip()]=v.strip()

sources={
    "GROQ_API_KEY":"/home/ubuntu/Claves/prov/groq.key",
    "OPENROUTER_API_KEY":"/home/ubuntu/Claves/providers/openrouter.key",
    "HF_TOKEN":"/home/ubuntu/Claves/providers/huggingface.key",
}
for name,raw in sources.items():
    p=Path(raw)
    if p.is_file():
        value=p.read_text(encoding="utf-8-sig").strip().strip('"').strip("'")
        if value:
            existing[name]=value

env_path.write_text("\n".join(f"{k}={v}" for k,v in existing.items())+"\n",encoding="utf-8")
env_path.chmod(0o600)
print("OPENCLAW_CREDENTIALS_READY")
PY
chown ubuntu:ubuntu "$OENV"

echo "=== 2. NATIVE OPENCLAW GATEWAY + MODEL POLICY ==="
if [ ! -s "$OTOKEN" ]; then
  openssl rand -hex 32 > "$OTOKEN"
fi
chmod 600 "$OTOKEN"
chown ubuntu:ubuntu "$OTOKEN"
TOKEN="$(cat "$OTOKEN")"

OC config set gateway.auth.mode token
OC config set gateway.auth.token "$TOKEN"
OC config set gateway.http.endpoints.chatCompletions.enabled true
OC config set tools.profile coding

# Only OpenClaw's own model/failover system is active.
# No Gemini providers.json, provider_state, Radar pool, or HF route file participates.
OC models set groq/openai/gpt-oss-120b
OC models fallbacks clear
OC models fallbacks add openrouter/openrouter/free

echo "=== 3. GEMINI UI BECOMES A THIN OPENCLAW CLIENT ==="
python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

# Remove the old early-return that sends normal chat to our legacy Router.
legacy='''

    # ROUTER_ONLY_NORMAL_CHAT
    # Normal conversation goes straight to the existing routed /api/chat.
    # Programming/VM requests continue below through Central.
    if not _looks_like_programming_request(message):
        return await _call_original_chat(data)
'''
s=s.replace(legacy,"\n")

helper_marker="# OPENCLAW_ONLY_HELPER"
if helper_marker not in s:
    route='@app.post("/api/chat/direct")'
    pos=s.find(route)
    if pos < 0:
        raise SystemExit("DIRECT_ROUTE_NOT_FOUND")
    helper=r'''
# OPENCLAW_ONLY_HELPER
async def _openclaw_only_turn(message: str, conversation_id: str) -> str:
    """Single brain: every turn is executed by the OpenClaw Gateway agent."""
    import asyncio
    import urllib.request
    import urllib.error

    def _call():
        token=Path("/home/ubuntu/.openclaw/gateway.token").read_text(encoding="utf-8").strip()
        payload={
            "model":"openclaw/default",
            "user":f"conv:{conversation_id}",
            "messages":[{"role":"user","content":message}],
            "stream":False,
        }
        req=urllib.request.Request(
            "http://127.0.0.1:18789/v1/chat/completions",
            data=json.dumps(payload,ensure_ascii=False).encode("utf-8"),
            headers={
                "Authorization":f"Bearer {token}",
                "Content-Type":"application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req,timeout=600) as r:
                raw=r.read().decode("utf-8",errors="replace")
        except urllib.error.HTTPError as e:
            raw=e.read().decode("utf-8",errors="replace")
            raise RuntimeError(f"OPENCLAW_HTTP_{e.code}: {raw[:1200]}")
        body=json.loads(raw or "{}")
        choices=body.get("choices") or []
        if not choices:
            raise RuntimeError("OPENCLAW_EMPTY_RESPONSE")
        msg=(choices[0].get("message") or {}).get("content")
        if isinstance(msg,list):
            parts=[]
            for item in msg:
                if isinstance(item,dict) and item.get("text"):
                    parts.append(str(item["text"]))
                elif isinstance(item,str):
                    parts.append(item)
            msg="\n".join(parts)
        answer=str(msg or "").strip()
        if not answer:
            raise RuntimeError("OPENCLAW_EMPTY_CONTENT")
        return answer

    return await asyncio.to_thread(_call)

'''
    s=s[:pos]+helper+"\n"+s[pos:]

branch_marker="    # OPENCLAW_ONLY_CHAT\n"
if branch_marker not in s:
    # Insert before the old Central/OpenClaw programming branch. At this point the
    # existing endpoint has already created the conversation and stored the user turn.
    anchors=[
        "    # Órdenes operativas/programación: Central gobierna, OpenClaw ejecuta.\n",
        "    file_rows = _direct_file_rows(",
    ]
    ins=-1
    for a in anchors:
        q=s.find(a)
        if q >= 0:
            ins=q
            break
    if ins < 0:
        raise SystemExit("DIRECT_EXECUTION_ANCHOR_NOT_FOUND")

    block=r'''    # OPENCLAW_ONLY_CHAT
    # Absolute isolation: Gemini UI never selects or calls a provider.
    # OpenClaw owns the model, provider, failover, tools and session.
    try:
        answer = await _openclaw_only_turn(message, cid)
        now2 = int(time.time())
        with db() as c:
            c.execute(
                """
                INSERT INTO messages
                (conversation_id, role, content, provider, model, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (cid, "assistant", answer, "openclaw", "openclaw/default", now2),
            )
            c.execute(
                "UPDATE conversations SET updated_at=? WHERE id=?",
                (now2, cid),
            )
        return {
            "ok": True,
            "conversation_id": cid,
            "execution_mode": "openclaw_only",
            "brain": "openclaw",
            "provider": "openclaw",
            "model": "openclaw/default",
            "answer": answer,
            "files": [],
        }
    except Exception as e:
        return {
            "ok": False,
            "conversation_id": cid,
            "execution_mode": "openclaw_only",
            "brain": "openclaw",
            "provider": "openclaw",
            "model": "openclaw/default",
            "answer": "Error OpenClaw: " + str(e),
            "files": [],
        }

'''
    s=s[:ins]+block+s[ins:]

p.write_text(s,encoding="utf-8")
print("GEMINI_OPENCLAW_ONLY_PATCHED")
PY

python3 -m py_compile "$MAIN"

echo "=== 4. RESTART OPENCLAW AND WAIT FOR REAL READINESS ==="
USYSTEMCTL restart openclaw-gateway.service

READY=0
for i in $(seq 1 210); do
  if curl -fsS --max-time 2 \
      -H "Authorization: Bearer $TOKEN" \
      http://127.0.0.1:18789/v1/models >/tmp/openclaw-models.json 2>/dev/null; then
    READY=1
    break
  fi
  sleep 1
done
[ "$READY" = "1" ] || { echo "OPENCLAW_GATEWAY_NOT_READY"; USYSTEMCTL status openclaw-gateway.service --no-pager -l || true; exit 1; }

echo "=== 5. RESTART GEMINI THIN CLIENT ==="
systemctl restart gemini-backend.service
for i in $(seq 1 40); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/gemini-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done
cat /tmp/gemini-health.json
echo

echo "=== 6. VERIFY ISOLATION ==="
grep -n 'OPENCLAW_ONLY_CHAT' "$MAIN"
if grep -n 'ROUTER_ONLY_NORMAL_CHAT' "$MAIN"; then
  echo "ERROR_LEGACY_ROUTER_BRANCH_STILL_ACTIVE"
  exit 1
fi

echo "--- OpenClaw models endpoint ---"
cat /tmp/openclaw-models.json
echo

echo "--- OpenClaw model policy ---"
OC models status || true
echo "--- OpenClaw fallbacks ---"
OC models fallbacks list --plain || true

echo "=== 7. REAL CHAT SMOKE TEST THROUGH GEMINI BACKEND ==="
python3 - <<'PY'
import json, urllib.request
payload={"message":"Respondé exactamente OPENCLAW_ONLY_OK"}
req=urllib.request.Request(
    "http://127.0.0.1:8791/api/chat/direct",
    data=json.dumps(payload).encode(),
    headers={"Content-Type":"application/json"},
    method="POST",
)
with urllib.request.urlopen(req,timeout=240) as r:
    body=json.loads(r.read().decode())
print(json.dumps(body,ensure_ascii=False))
if body.get("execution_mode")!="openclaw_only":
    raise SystemExit("NOT_OPENCLAW_ONLY")
if "OPENCLAW_ONLY_OK" not in str(body.get("answer") or ""):
    raise SystemExit("OPENCLAW_CHAT_SMOKE_FAILED")
print("OPENCLAW_ONLY_SMOKE_OK")
PY

echo OPENCLAW_ONLY_READY
