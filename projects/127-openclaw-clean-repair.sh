#!/usr/bin/env bash
set -euo pipefail

OCFG=/home/ubuntu/.openclaw/openclaw.json
OPENCLAW=/home/ubuntu/.npm-global/bin/openclaw
TOKEN=/home/ubuntu/.openclaw/gateway.token
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/.openclaw/backups/clean-repair-$STAMP

mkdir -p "$BACKUP"
cp -a "$OCFG" "$BACKUP/openclaw.json"

test -x "$OPENCLAW" || { echo OPENCLAW_NOT_FOUND; exit 1; }
test -s "$TOKEN" || { echo TOKEN_NOT_FOUND; exit 1; }

echo "=== 1. REPAIR CLEAN OPENCLAW CONFIG ==="
python3 - <<'PY'
import json
from pathlib import Path

p=Path("/home/ubuntu/.openclaw/openclaw.json")
cfg=json.loads(p.read_text(encoding="utf-8"))

agents=cfg.setdefault("agents",{})
defaults=agents.setdefault("defaults",{})

defaults["skipBootstrap"]=True
defaults["contextInjection"]="never"
defaults["thinkingDefault"]="off"
defaults["fastModeDefault"]=True
defaults["skills"]=[]
defaults["startupContext"]={
    "enabled": False,
    "applyOn": [],
    "dailyMemoryDays": 1,
    "maxFileBytes": 1,
    "maxFileChars": 1,
    "maxTotalChars": 1,
}

cfg.setdefault("tools",{})["profile"]="minimal"

models=cfg.setdefault("models",{})
providers=models.setdefault("providers",{})
groq=providers.setdefault("groq",{})
groq["baseUrl"]="https://api.groq.com/openai/v1"
groq["api"]="openai-completions"
groq["apiKey"]="$"+"{GROQ_API_KEY}"

lst=groq.setdefault("models",[])
if not any(isinstance(x,dict) and x.get("id")=="openai/gpt-oss-120b" for x in lst):
    lst.append({"id":"openai/gpt-oss-120b","name":"openai/gpt-oss-120b"})

p.write_text(json.dumps(cfg,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("CLEAN_CONFIG_WRITTEN")
print("groq.baseUrl=https://api.groq.com/openai/v1")
print("thinking=off fast=true bootstrap=false context=never")
PY
chown ubuntu:ubuntu "$OCFG"
chmod 600 "$OCFG"

echo "=== 2. RESTART OPENCLAW ==="
UIDU="$(id -u ubuntu)"
runuser -u ubuntu -- env HOME=/home/ubuntu XDG_RUNTIME_DIR="/run/user/$UIDU" PATH="/home/ubuntu/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" systemctl --user restart openclaw-gateway.service

AUTH="$(cat "$TOKEN")"
READY=0
for i in $(seq 1 210); do
  if curl -fsS --max-time 2 -H "Authorization: Bearer $AUTH" http://127.0.0.1:18789/v1/models >/dev/null 2>&1; then
    READY=1; break
  fi
  sleep 1
done
[ "$READY" = 1 ] || {
  echo OPENCLAW_NOT_READY
  runuser -u ubuntu -- env HOME=/home/ubuntu XDG_RUNTIME_DIR="/run/user/$UIDU" systemctl --user status openclaw-gateway.service --no-pager -l || true
  exit 1
}
echo GATEWAY_READY

echo "=== 3. THREE DIRECT TESTS ==="
python3 - <<'PY'
import json,time,urllib.request
from pathlib import Path
token=Path("/home/ubuntu/.openclaw/gateway.token").read_text().strip()
url="http://127.0.0.1:18789/v1/chat/completions"
for i in range(1,4):
    payload={
      "model":"openclaw/default",
      "user":f"clean-{int(time.time())}-{i}",
      "messages":[{"role":"user","content":"Respondé exactamente HOLA"}],
      "stream":False,
    }
    req=urllib.request.Request(url,data=json.dumps(payload).encode(),headers={
      "Authorization":f"Bearer {token}",
      "Content-Type":"application/json",
    },method="POST")
    t=time.monotonic()
    try:
      with urllib.request.urlopen(req,timeout=180) as r:
        body=json.loads(r.read().decode())
      sec=round(time.monotonic()-t,3)
      usage=body.get("usage") or {}
      ans=((body.get("choices") or [{}])[0].get("message") or {}).get("content")
      print(json.dumps({
        "run":i,"seconds":sec,"answer":ans,
        "prompt_tokens":usage.get("prompt_tokens"),
        "completion_tokens":usage.get("completion_tokens"),
        "reasoning_tokens":(usage.get("completion_tokens_details") or {}).get("reasoning_tokens")
      },ensure_ascii=False))
    except Exception as e:
      print(json.dumps({"run":i,"seconds":round(time.monotonic()-t,3),"error":str(e)},ensure_ascii=False))
PY

echo "=== 4. GROQ ERRORS AFTER TEST ==="
journalctl --user -u openclaw-gateway.service --since "-10 min" --no-pager | grep -E 'requires an explicit base URL|provider=groq|fallback decision' | tail -40 || true

echo OPENCLAW_CLEAN_REPAIR_READY
