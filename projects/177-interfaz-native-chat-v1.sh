#!/usr/bin/env bash
set -euo pipefail

APP=/home/ubuntu/Interfaz
SERVER="$APP/server.py"
NATIVE=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/interfaz-native-chat-v1-$STAMP

mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. INSTALL CENTRAL NATIVE CONVERSATIONAL RUNNER ==="
cat >"$NATIVE/native_chat.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import json, sys, time
from config import load_settings
from providers import ProviderRegistry
from router import select

STATE="/home/ubuntu/Central/state/providers.json"

SYSTEM=(
    "Sos la capa conversacional de Central. Respondé en español claro y natural. "
    "Mantené continuidad con el historial. No afirmes haber ejecutado cambios en la VM "
    "si no fueron realizados por Central Jobs. Si el usuario sólo conversa o pregunta, "
    "respondé directamente."
)

def main():
    payload=json.load(sys.stdin)
    messages=payload.get("messages") or []
    extra=str(payload.get("extra_context") or "").strip()

    clean=[]
    for m in messages[-24:]:
        role=str(m.get("role") or "")
        content=str(m.get("content") or "")
        if role in ("user","assistant") and content:
            clean.append({"role":role,"content":content})

    if extra and clean and clean[-1]["role"]=="user":
        clean[-1]["content"] += "\n\n[CONTEXTO DE ADJUNTOS]\n"+extra

    cfg=load_settings()
    registry=ProviderRegistry(cfg.groq_key,cfg.openrouter_key,STATE)
    ranked=select("conversacion",registry)
    if not ranked:
        raise SystemExit("NO_CONVERSATION_ROUTE")

    attempts=[]
    for item in ranked[:8]:
        ref=item["ref"]
        provider_name,model=ref.split("/",1)
        provider=registry.providers.get(provider_name)
        if provider is None:
            continue
        started=time.monotonic()
        try:
            out=provider.chat(
                model,
                [{"role":"system","content":SYSTEM}]+clean,
                max_tokens=1200,
                temperature=0.35,
            )
            latency_ms=round((time.monotonic()-started)*1000)
            answer=((out.get("choices") or [{}])[0].get("message") or {}).get("content","").strip()
            if not answer:
                raise RuntimeError("EMPTY_CHAT_ANSWER")
            registry.record_result(ref,True,latency_ms,1.0,"conversacion")
            print(json.dumps({
                "ok":True,
                "answer":answer,
                "provider":provider_name,
                "model":model,
                "model_ref":ref,
                "capability":"conversacion",
                "router_score":item.get("score"),
                "attempts":attempts+[{"ref":ref,"ok":True,"latency_ms":latency_ms}],
            },ensure_ascii=False))
            return
        except Exception as e:
            latency_ms=round((time.monotonic()-started)*1000)
            attempts.append({"ref":ref,"ok":False,"latency_ms":latency_ms,"error":str(e)[:240]})
            try:
                registry.record_result(ref,False,latency_ms,0.0,"conversacion")
            except Exception:
                pass

    print(json.dumps({"ok":False,"error":"ALL_CONVERSATION_MODELS_FAILED","attempts":attempts},ensure_ascii=False))
    raise SystemExit(1)

if __name__=="__main__":
    main()
PY
chmod 755 "$NATIVE/native_chat.py"
python3 -m py_compile "$NATIVE/native_chat.py"
echo CENTRAL_NATIVE_CHAT_RUNNER_OK

echo "=== 2. DIRECT NATIVE CHAT SMOKE ==="
REQ=/tmp/native-chat-smoke.json
cat >"$REQ" <<'JSON'
{"messages":[{"role":"user","content":"Respondé exactamente CENTRAL_NATIVE_CHAT_OK"}]}
JSON
OUT=$(sudo -u ubuntu env PYTHONPATH="$NATIVE" /usr/bin/python3 "$NATIVE/native_chat.py" < "$REQ")
echo "$OUT"
OUT_JSON="$OUT" python3 - <<'PY'
import json,os
x=json.loads(os.environ["OUT_JSON"])
assert x["ok"] is True,x
assert "CENTRAL_NATIVE_CHAT_OK" in x["answer"],x
assert x["capability"]=="conversacion",x
assert x["model_ref"],x
print("CENTRAL_NATIVE_CHAT_SMOKE_OK")
print("model_ref="+x["model_ref"])
PY

echo "=== 3. REMOVE OPENCLAW FROM INTERFAZ CONVERSATION PATH ==="
python3 - <<'PY'
from pathlib import Path
import re
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

# Remove old constants if present.
s=re.sub(r'^OPENCLAW=.*\n','',s,flags=re.M)
s=re.sub(r'^TOKEN_PATH=.*\n','',s,flags=re.M)

start=s.find('def call_openclaw(')
if start<0:
    start=s.find('def call_central_native_chat(')

if start<0:
    raise SystemExit("CHAT_FUNCTION_NOT_FOUND")

end=s.find('\nclass H(',start)
if end<0:
    raise SystemExit("CHAT_FUNCTION_END_NOT_FOUND")

new_func='''def call_central_native_chat(cid, text, extra_context=""):
    msgs=history(cid,16)
    payload={"messages":msgs,"extra_context":extra_context}
    env=dict(os.environ)
    env["PYTHONPATH"]="/home/ubuntu/Central/native_v1"
    cp=subprocess.run(
        ["/usr/bin/python3","/home/ubuntu/Central/native_v1/native_chat.py"],
        input=json.dumps(payload,ensure_ascii=False),
        text=True,capture_output=True,timeout=120,env=env
    )
    if cp.returncode!=0:
        raise RuntimeError("CENTRAL_NATIVE_CHAT_FAILED:"+(cp.stderr or cp.stdout)[-600:])
    out=json.loads(cp.stdout)
    if not out.get("ok"):
        raise RuntimeError(str(out.get("error") or "CENTRAL_NATIVE_CHAT_FAILED"))
    return str(out.get("answer") or "").strip()
'''

s=s[:start]+new_func+s[end:]
s=s.replace('answer=call_openclaw(cid,text,extra)','answer=call_central_native_chat(cid,text,extra)')
s=s.replace('answer=call_openclaw(cid,text)','answer=call_central_native_chat(cid,text)')

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
if grep -qiE 'openclaw|127\.0\.0\.1:18789' "$SERVER"; then
  echo "ERROR: OpenClaw reference remains in Interfaz"
  grep -niE 'openclaw|127\.0\.0\.1:18789' "$SERVER" || true
  exit 1
fi
echo INTERFAZ_OPENCLAW_DEPENDENCY_REMOVED_OK

echo "=== 4. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/interfaz-native-chat-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/interfaz-native-chat-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_NATIVE_CHAT_SERVICE_OK

echo "=== 5. REAL INTERFAZ CONVERSATION TEST ==="
CHATREQ=/tmp/interfaz-native-chat-message.json
cat >"$CHATREQ" <<'JSON'
{"text":"Respondé exactamente INTERFAZ_NATIVE_CHAT_OK"}
JSON
CHAT=$(curl -fsS --max-time 150 -H 'Content-Type: application/json' --data-binary @"$CHATREQ" http://127.0.0.1:8791/api/message)
echo "$CHAT"
CHAT_JSON="$CHAT" python3 - <<'PY'
import json,os
x=json.loads(os.environ["CHAT_JSON"])
assert x["ok"] is True,x
assert x["mode"]=="chat",x
assert "INTERFAZ_NATIVE_CHAT_OK" in x["answer"],x
print("INTERFAZ_NATIVE_CHAT_LIVE_OK")
PY

echo "=== 6. OPERATIONAL PATH REGRESSION ==="
OPREQ=/tmp/interfaz-native-operational.json
cat >"$OPREQ" <<'JSON'
{"text":"Creá el archivo native-chat-regression.txt que contenga exactamente NATIVE_CHAT_OPERATIONAL_OK, leelo y verificá que coincida."}
JSON
OP=$(curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @"$OPREQ" http://127.0.0.1:8791/api/message)
echo "$OP"
JOB=$(OP_JSON="$OP" python3 - <<'PY'
import json,os
x=json.loads(os.environ["OP_JSON"])
assert x["ok"] is True,x
assert x["mode"]=="job",x
print(x["job_id"])
PY
)

for i in $(seq 1 120); do
  J=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB")
  S=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$J")
  printf '\rstatus=%s elapsed=%ss' "$S" "$i"
  case "$S" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
echo
J_JSON="$J" python3 - <<'PY'
import json,os
j=json.loads(os.environ["J_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
n=(j.get("result") or {}).get("native") or {}
assert n.get("capability")=="programacion",n
print("INTERFAZ_OPERATIONAL_PATH_REGRESSION_OK")
PY
grep -qx 'NATIVE_CHAT_OPERATIONAL_OK' "/home/ubuntu/Central/work/$JOB/native-chat-regression.txt"

echo "=== 7. OPENCLAW STATUS (ROLLBACK ONLY, NOT IN PATH) ==="
systemctl --user is-active openclaw-gateway.service 2>/dev/null || true
echo OPENCLAW_NOT_IN_INTERFAZ_PATH

cat >"$NATIVE/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "interfaz-native-chat-v1",
  "normal_conversation": "Central Native",
  "operational_execution": "Central Jobs -> Central Native",
  "openclaw_in_interfaz_path": false,
  "openclaw_installation_kept_for_rollback": true,
  "active": true
}
EOF

echo CENTRAL_INTERFAZ_NATIVE_CHAT_V1_READY
echo "URL=https://cen-tral.duckdns.org/interfaz/"
echo "backup=$BACKUP"
