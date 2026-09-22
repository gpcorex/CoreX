#!/usr/bin/env bash
set -euo pipefail

OCFG=/home/ubuntu/.openclaw/openclaw.json
TOKEN=/home/ubuntu/.openclaw/gateway.token
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/.openclaw/backups/programming-fix-$STAMP

mkdir -p "$BACKUP"
cp -a "$OCFG" "$BACKUP/openclaw.json"

echo "=== 1. PATCH OPENCLAW TOOL POLICY + GROQ LIMITS ==="
python3 - <<'PY'
import json
from pathlib import Path

p=Path("/home/ubuntu/.openclaw/openclaw.json")
cfg=json.loads(p.read_text(encoding="utf-8"))

tools=cfg.setdefault("tools",{})
tools["profile"]="minimal"
tools["alsoAllow"]=["exec","process","read","write","edit"]

models=cfg.setdefault("models",{})
providers=models.setdefault("providers",{})
groq=providers.setdefault("groq",{})
groq["baseUrl"]="https://api.groq.com/openai/v1"
groq["api"]="openai-completions"
groq["apiKey"]="$"+"{GROQ_API_KEY}"

wanted={
  "openai/gpt-oss-20b":{
    "id":"openai/gpt-oss-20b",
    "name":"openai/gpt-oss-20b",
    "contextWindow":131072,
    "contextTokens":32768,
    "maxTokens":8192
  },
  "openai/gpt-oss-120b":{
    "id":"openai/gpt-oss-120b",
    "name":"openai/gpt-oss-120b",
    "contextWindow":131072,
    "contextTokens":32768,
    "maxTokens":8192
  },
}
old=groq.get("models") or []
out=[]
seen=set()
for row in old:
    if isinstance(row,dict) and row.get("id") in wanted:
        out.append(wanted[row["id"]]); seen.add(row["id"])
    else:
        out.append(row)
for k,v in wanted.items():
    if k not in seen: out.append(v)
groq["models"]=out

defaults=cfg.setdefault("agents",{}).setdefault("defaults",{})
defaults.setdefault("model",{})["primary"]="groq/openai/gpt-oss-20b"

p.write_text(json.dumps(cfg,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("tools.profile=minimal")
print("tools.alsoAllow=exec,process,read,write,edit")
print("groq.maxTokens=8192")
print("groq.contextTokens=32768")
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
[ "$READY" = 1 ] || { echo OPENCLAW_NOT_READY; exit 1; }
echo OPENCLAW_READY

echo "=== 3. CENTRAL -> OPENCLAW PROGRAMMING SMOKE ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá un programa en /tmp/interfaz-programacion/prueba2.py que imprima exactamente PROGRAMACION_OK_2. Creá la carpeta si no existe, ejecutá el programa y verificá que la salida sea exactamente PROGRAMACION_OK_2.","source":"interfaz","project":"Interfaz","conversation_id":"programming-smoke"}' \
  http://127.0.0.1:8091/api/jobs)
echo "$RESP"
JOB_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP")

for i in $(seq 1 240); do
  OUT=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB_ID")
  STATUS=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
  printf '\rstatus=%s elapsed=%ss' "$STATUS" "$i"
  case "$STATUS" in COMPLETADA|ERROR) break ;; esac
  sleep 1
done
echo
echo "$OUT"

OUT_JSON="$OUT" python3 - <<'PY'
import json,os,subprocess
o=json.loads(os.environ["OUT_JSON"])
j=o["job"]
assert j["status"]=="COMPLETADA", j
p="/tmp/interfaz-programacion/prueba2.py"
assert os.path.isfile(p), p
cp=subprocess.run(["python3",p],capture_output=True,text=True,timeout=10)
assert cp.returncode==0, cp.stderr
assert cp.stdout.strip()=="PROGRAMACION_OK_2", cp.stdout
print("CENTRAL_OPENCLAW_PROGRAMMING_OK")
PY

echo "=== 4. RECENT OPENCLAW ERRORS ==="
runuser -u ubuntu -- env HOME=/home/ubuntu XDG_RUNTIME_DIR="/run/user/$UIDU" journalctl --user -u openclaw-gateway.service --since "-10 min" --no-pager 2>/dev/null | grep -Ei 'tool call validation|max_completion_tokens|provider rejected|error=' | tail -40 || true

echo "backup=$BACKUP"
echo OPENCLAW_PROGRAMMING_FIX_READY
