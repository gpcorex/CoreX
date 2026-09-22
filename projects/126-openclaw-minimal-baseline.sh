#!/usr/bin/env bash
set -euo pipefail

OCFG=/home/ubuntu/.openclaw/openclaw.json
OPENCLAW=/home/ubuntu/.npm-global/bin/openclaw
TOKEN_FILE=/home/ubuntu/.openclaw/gateway.token
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/.openclaw/backups/minimal-baseline-$STAMP

mkdir -p "$BACKUP"
cp -a "$OCFG" "$BACKUP/openclaw.json"

test -x "$OPENCLAW" || { echo "OPENCLAW_NOT_FOUND"; exit 1; }
test -s "$TOKEN_FILE" || { echo "TOKEN_NOT_FOUND"; exit 1; }

echo "=== 1. BACKUP ==="
echo "$BACKUP/openclaw.json"

echo "=== 2. MINIMAL OPENCLAW BASELINE ==="
python3 - <<'PY'
import json
from pathlib import Path

p=Path("/home/ubuntu/.openclaw/openclaw.json")
cfg=json.loads(p.read_text(encoding="utf-8"))

agents=cfg.setdefault("agents",{})
defaults=agents.setdefault("defaults",{})

# Clean baseline: no bootstrap/context/memory skills/tools overhead.
defaults["skipBootstrap"]=True
defaults["contextInjection"]="never"
defaults["thinkingDefault"]="off"
defaults["fastModeDefault"]=True
defaults["skills"]=[]
defaults["startupContext"]={
    "enabled": False,
    "applyOn": [],
    "dailyMemoryDays": 0,
    "maxFileBytes": 0,
    "maxFileChars": 0,
    "maxTotalChars": 0,
}

# Preserve provider/model policy already configured by OpenClaw.
tools=cfg.setdefault("tools",{})
tools["profile"]="minimal"

p.write_text(json.dumps(cfg,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("skipBootstrap=true")
print("contextInjection=never")
print("thinkingDefault=off")
print("fastModeDefault=true")
print("skills=[]")
print("startupContext.enabled=false")
print("tools.profile=minimal")
PY
chown ubuntu:ubuntu "$OCFG"
chmod 600 "$OCFG"

echo "=== 3. RESTART GATEWAY ==="
UID_UBUNTU="$(id -u ubuntu)"
runuser -u ubuntu -- env   HOME=/home/ubuntu   XDG_RUNTIME_DIR="/run/user/$UID_UBUNTU"   PATH="/home/ubuntu/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"   systemctl --user restart openclaw-gateway.service

TOKEN="$(cat "$TOKEN_FILE")"
READY=0
for i in $(seq 1 210); do
  if curl -fsS --max-time 2       -H "Authorization: Bearer $TOKEN"       http://127.0.0.1:18789/v1/models >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 1
done
[ "$READY" = "1" ] || { echo "OPENCLAW_NOT_READY"; exit 1; }
echo "GATEWAY_READY"

echo "=== 4. EFFECTIVE CONFIG ==="
python3 - <<'PY'
import json
from pathlib import Path
cfg=json.loads(Path("/home/ubuntu/.openclaw/openclaw.json").read_text())
d=cfg.get("agents",{}).get("defaults",{})
print("thinkingDefault=",d.get("thinkingDefault"))
print("fastModeDefault=",d.get("fastModeDefault"))
print("contextInjection=",d.get("contextInjection"))
print("skipBootstrap=",d.get("skipBootstrap"))
print("skills=",d.get("skills"))
print("startupContext=",d.get("startupContext"))
print("tools.profile=",cfg.get("tools",{}).get("profile"))
print("model=",d.get("model"))
PY

echo "=== 5. THREE CLEAN CHAT RUNS ==="
python3 - <<'PY'
import json, time, urllib.request
from pathlib import Path

token=Path("/home/ubuntu/.openclaw/gateway.token").read_text().strip()
url="http://127.0.0.1:18789/v1/chat/completions"

for i in range(1,4):
    payload={
        "model":"openclaw/default",
        "user":f"baseline-{int(time.time())}-{i}",
        "messages":[{"role":"user","content":"Respondé exactamente HOLA"}],
        "stream":False,
    }
    req=urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={
            "Authorization":f"Bearer {token}",
            "Content-Type":"application/json",
        },
        method="POST",
    )
    t=time.monotonic()
    try:
        with urllib.request.urlopen(req,timeout=180) as r:
            body=json.loads(r.read().decode())
        sec=round(time.monotonic()-t,3)
        usage=body.get("usage") or {}
        answer=((body.get("choices") or [{}])[0].get("message") or {}).get("content")
        print(json.dumps({
            "run":i,
            "seconds":sec,
            "answer":answer,
            "prompt_tokens":usage.get("prompt_tokens"),
            "completion_tokens":usage.get("completion_tokens"),
            "reasoning_tokens":(usage.get("completion_tokens_details") or {}).get("reasoning_tokens"),
        },ensure_ascii=False))
    except Exception as e:
        sec=round(time.monotonic()-t,3)
        print(json.dumps({"run":i,"seconds":sec,"error":str(e)},ensure_ascii=False))

PY

echo OPENCLAW_MINIMAL_BASELINE_READY
