#!/usr/bin/env bash
set -euo pipefail

OCFG=/home/ubuntu/.openclaw/openclaw.json
TOKEN=/home/ubuntu/.openclaw/gateway.token
GROQ_KEY_FILE=/home/ubuntu/Claves/prov/groq.key
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/.openclaw/backups/programming-tools-$STAMP

mkdir -p "$BACKUP"
cp -a "$OCFG" "$BACKUP/openclaw.json"

[ -s "$TOKEN" ] || { echo OPENCLAW_TOKEN_NOT_FOUND; exit 1; }
[ -s "$GROQ_KEY_FILE" ] || { echo GROQ_KEY_NOT_FOUND; exit 1; }

echo "=== 1. VERIFY GROQ MODELS DIRECTLY ==="
GROQ_KEY="$(tr -d '\r\n' < "$GROQ_KEY_FILE")"
for MODEL in openai/gpt-oss-20b qwen/qwen3.8-27b openai/gpt-oss-120b; do
  TMP=$(mktemp)
  CODE=$(curl -sS -o "$TMP" -w '%{http_code}' --max-time 60 \
    -H "Authorization: Bearer $GROQ_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Respondé exactamente OK\"}],\"max_completion_tokens\":64}" \
    https://api.groq.com/openai/v1/chat/completions || true)
  printf '%s http=%s ' "$MODEL" "$CODE"
  python3 - "$TMP" <<'PY'
import json,sys
raw=open(sys.argv[1],encoding="utf-8",errors="replace").read()
try:
    x=json.loads(raw)
    if "error" in x:
        print("ERROR", json.dumps(x["error"],ensure_ascii=False))
    else:
        m=((x.get("choices") or [{}])[0].get("message") or {})
        print("content="+repr(m.get("content")))
except Exception:
    print(raw[:500])
PY
  rm -f "$TMP"
done

echo "=== 2. ENABLE MINIMAL PROGRAMMING TOOLS ==="
python3 - <<'PY'
import json
from pathlib import Path

p=Path("/home/ubuntu/.openclaw/openclaw.json")
cfg=json.loads(p.read_text(encoding="utf-8"))

tools=cfg.setdefault("tools",{})
tools["profile"]="minimal"
tools["alsoAllow"]=["exec","process","read","write","edit"]

p.write_text(json.dumps(cfg,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print(json.dumps(cfg["tools"],ensure_ascii=False))
PY
chown ubuntu:ubuntu "$OCFG"
chmod 600 "$OCFG"

echo "=== 3. RESTART OPENCLAW ==="
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
echo OPENCLAW_READY

echo "=== 4. VERIFY EFFECTIVE TOOLS CONFIG ==="
python3 - <<'PY'
import json
from pathlib import Path
cfg=json.loads(Path("/home/ubuntu/.openclaw/openclaw.json").read_text())
print(json.dumps(cfg.get("tools",{}),ensure_ascii=False))
t=cfg.get("tools",{})
assert t.get("profile")=="minimal", t
assert t.get("alsoAllow")==["exec","process","read","write","edit"], t
print("OPENCLAW_PROGRAMMING_TOOLS_CONFIG_OK")
PY

echo "=== 5. CENTRAL -> OPENCLAW -> VM SMOKE ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá un programa en /tmp/interfaz-programacion/final-smoke.py que imprima exactamente OPENCLAW_PROGRAMMING_OK. Creá la carpeta si no existe, ejecutá el programa y verificá que la salida sea exactamente OPENCLAW_PROGRAMMING_OK.","source":"interfaz","project":"Interfaz","conversation_id":"final-programming-smoke"}' \
  http://127.0.0.1:8091/api/jobs)
echo "$RESP"
JOB_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP")

for i in $(seq 1 300); do
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
p="/tmp/interfaz-programacion/final-smoke.py"
assert os.path.isfile(p), p
cp=subprocess.run(["python3",p],capture_output=True,text=True,timeout=10)
assert cp.returncode==0, cp.stderr
assert cp.stdout.strip()=="OPENCLAW_PROGRAMMING_OK", cp.stdout
print("CENTRAL_OPENCLAW_PROGRAMMING_OK")
PY

echo "=== 6. RECENT OPENCLAW ERRORS ==="
runuser -u ubuntu -- env HOME=/home/ubuntu XDG_RUNTIME_DIR="/run/user/$UIDU" journalctl --user -u openclaw-gateway.service --since "-15 min" --no-pager 2>/dev/null | grep -Ei 'tool call validation|max_completion_tokens|provider rejected|error=' | tail -60 || true

echo "backup=$BACKUP"
echo OPENCLAW_PROGRAMMING_STACK_READY
