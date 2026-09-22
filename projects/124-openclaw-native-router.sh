#!/usr/bin/env bash
set -euo pipefail

OPENCLAW=/home/ubuntu/.npm-global/bin/openclaw
OCFG=/home/ubuntu/.openclaw/openclaw.json
OENV=/home/ubuntu/.openclaw/.env
EXEC=/home/ubuntu/Central/runtime/executor.js
MAIN=/home/ubuntu/Gemini/app/main.py
HF_ROUTES=/home/ubuntu/Gemini/config/huggingface_zero_routes.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/openclaw-native-router-$STAMP

mkdir -p "$BACKUP"
cp -a "$OCFG" "$BACKUP/openclaw.json" 2>/dev/null || true
cp -a "$EXEC" "$BACKUP/executor.js"
cp -a "$MAIN" "$BACKUP/main.py"
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

echo "=== 1. PERSIST PROVIDER KEYS FOR OPENCLAW ==="
python3 - <<'PY'
from pathlib import Path

env_path=Path("/home/ubuntu/.openclaw/.env")
env_path.parent.mkdir(parents=True,exist_ok=True)

pairs={
    "GROQ_API_KEY": Path("/home/ubuntu/Claves/prov/groq.key"),
    "OPENROUTER_API_KEY": Path("/home/ubuntu/Claves/providers/openrouter.key"),
    "HF_TOKEN": Path("/home/ubuntu/Claves/providers/huggingface.key"),
}

existing={}
if env_path.exists():
    for line in env_path.read_text(encoding="utf-8",errors="replace").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k,v=line.split("=",1)
            existing[k.strip()]=v.strip()

for name,path in pairs.items():
    if path.is_file():
        value=path.read_text(encoding="utf-8-sig").strip().strip('"').strip("'")
        if value:
            existing[name]=value

env_path.write_text(
    "\n".join(f"{k}={v}" for k,v in existing.items())+"\n",
    encoding="utf-8",
)
env_path.chmod(0o600)
print("OPENCLAW_ENV_READY", ",".join(k for k in pairs if k in existing))
PY
chown ubuntu:ubuntu "$OENV"

echo "=== 2. REMOVE FIXED MODEL FROM CENTRAL EXECUTOR ==="
python3 - <<'PY'
from pathlib import Path
import re

p=Path("/home/ubuntu/Central/runtime/executor.js")
s=p.read_text(encoding="utf-8")

before=s
s=re.sub(
    r'\n\s*"--model",\s*"[^"]+",',
    '',
    s,
    count=1,
)

if s==before:
    print("EXECUTOR_MODEL_PIN_NOT_FOUND_OR_ALREADY_REMOVED")
else:
    p.write_text(s,encoding="utf-8")
    print("EXECUTOR_MODEL_PIN_REMOVED")
PY

node --check "$EXEC"

echo "=== 3. BUILD OPENCLAW FALLBACK CHAIN ==="
HF_FALLBACKS=$(python3 - <<'PY'
import json
from pathlib import Path

p=Path("/home/ubuntu/Gemini/config/huggingface_zero_routes.json")
seen=[]
if p.exists():
    try:
        routes=json.loads(p.read_text(encoding="utf-8")).get("routes") or []
    except Exception:
        routes=[]
    for item in routes:
        route=str(item.get("route") or "")
        if ":" not in route:
            continue
        model=route.rsplit(":",1)[0]
        ref="huggingface/"+model+":cheapest"
        if ref not in seen:
            seen.append(ref)

for ref in seen[:2]:
    print(ref)
PY
)

OC models set groq/openai/gpt-oss-120b
OC models fallbacks clear
OC models fallbacks add openrouter/openrouter/free

while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  OC models fallbacks add "$ref" || true
done <<< "$HF_FALLBACKS"

echo "=== 4. RESTORE GEMINI PROGRAMMING VIA CENTRAL/OPENCLAW ==="
python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

start_marker='''    # Programación nativa: Router elige el modelo; Central ejecuta herramientas.
    if _looks_like_programming_request(message):
'''
start=s.find(start_marker)

if start < 0:
    print("NATIVE_PROGRAMMER_BRANCH_NOT_FOUND_OR_ALREADY_DISABLED")
else:
    next_marker='''    # Órdenes operativas/programación: Central gobierna, OpenClaw ejecuta.
    if _looks_like_programming_request(message):
'''
    end=s.find(next_marker,start+len(start_marker))
    if end < 0:
        raise SystemExit("ORIGINAL_CENTRAL_BRANCH_NOT_FOUND")
    s=s[:start]+s[end:]
    p.write_text(s,encoding="utf-8")
    print("NATIVE_PROGRAMMER_BRANCH_REMOVED")
PY

python3 -m py_compile "$MAIN"

echo "=== 5. RESTART SERVICES ==="
USYSTEMCTL restart openclaw-gateway.service

for i in $(seq 1 70); do
  if ss -ltn 2>/dev/null | grep -q ':18789 '; then
    break
  fi
  sleep 1
done

systemctl restart gemini-backend.service

for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/oc-native-gemini-health.json 2>/dev/null && break
  sleep 1
done

echo "=== 6. VERIFY ==="
echo "--- OpenClaw model status ---"
OC models status || true

echo "--- OpenClaw fallbacks ---"
OC models fallbacks list --plain || true

echo "--- Executor has fixed --model? ---"
if grep -n -- '"--model"' "$EXEC"; then
  echo "ERROR_FIXED_MODEL_STILL_PRESENT"
  exit 1
else
  echo "NO_FIXED_MODEL_OK"
fi

echo "--- Gateway ---"
USYSTEMCTL is-active openclaw-gateway.service
ss -ltnp | grep 18789 || { echo "OPENCLAW_PORT_NOT_READY"; exit 1; }

echo "--- Gemini ---"
cat /tmp/oc-native-gemini-health.json
echo

echo OPENCLAW_NATIVE_ROUTER_READY
