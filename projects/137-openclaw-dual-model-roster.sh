#!/usr/bin/env bash
set -euo pipefail

OCFG=/home/ubuntu/.openclaw/openclaw.json
ORKEY_FILE=/home/ubuntu/Claves/providers/openrouter.key
TOKEN=/home/ubuntu/.openclaw/gateway.token
ROSTER=/home/ubuntu/Central/config/model-roster.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/.openclaw/backups/dual-roster-$STAMP

mkdir -p "$BACKUP" "$(dirname "$ROSTER")"
cp -a "$OCFG" "$BACKUP/openclaw.json"
[ -f "$ROSTER" ] && cp -a "$ROSTER" "$BACKUP/model-roster.json" || true

[ -s "$ORKEY_FILE" ] || { echo OPENROUTER_KEY_NOT_FOUND; exit 1; }
[ -s "$TOKEN" ] || { echo OPENCLAW_TOKEN_NOT_FOUND; exit 1; }

echo "=== 1. VERIFY OPENROUTER KEY + CURRENT FREE MODELS ==="
ORKEY="$(tr -d '\r\n' < "$ORKEY_FILE")"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
HTTP=$(curl -sS -o "$TMP" -w '%{http_code}' --max-time 25 \
  -H "Authorization: Bearer $ORKEY" \
  https://openrouter.ai/api/v1/models)
echo "openrouter_http=$HTTP"
[ "$HTTP" = 200 ] || { cat "$TMP"; exit 1; }

echo "=== 2. BUILD TWO VERIFIED ROSTERS ==="
OPENROUTER_MODELS_JSON="$TMP" python3 - <<'PY'
import json, os
from pathlib import Path

models=json.load(open(os.environ["OPENROUTER_MODELS_JSON"],encoding="utf-8")).get("data",[])
available={m.get("id") for m in models if isinstance(m,dict) and m.get("id")}

groq=[
  {"id":"groq/openai/gpt-oss-20b","role":"rapido","provider":"groq"},
  {"id":"groq/qwen/qwen3.8-27b","role":"tecnico","provider":"groq"},
  {"id":"groq/openai/gpt-oss-120b","role":"fuerte","provider":"groq"},
]

preferred=[
  ("poolside/laguna-s-2.1:free","coding"),
  ("cohere/north-mini-code:free","coding-rapido"),
  ("nvidia/nemotron-3.5-lightning:free","agentico-rapido"),
  ("nvidia/nemotron-3-ultra-550b-a55b:free","agentico-fuerte"),
]
openrouter=[]
for mid,role in preferred:
    if mid in available:
        openrouter.append({"id":"openrouter/"+mid,"role":role,"provider":"openrouter","free":True})

# Always keep OpenRouter's free router as the last safety net.
openrouter.append({"id":"openrouter/free","role":"red-seguridad","provider":"openrouter","free":True})

roster={
  "version":1,
  "policy":{
    "primary":"groq/openai/gpt-oss-20b",
    "fallback_order":[
      "groq/qwen/qwen3.8-27b",
      "groq/openai/gpt-oss-120b",
      *[x["id"] for x in openrouter]
    ]
  },
  "groq":groq,
  "openrouter":openrouter
}

Path("/home/ubuntu/Central/config/model-roster.json").write_text(
  json.dumps(roster,ensure_ascii=False,indent=2)+"\n",encoding="utf-8"
)
print("GROQ_ROSTER")
for x in groq: print(" ",x["id"],"->",x["role"])
print("OPENROUTER_ROSTER")
for x in openrouter: print(" ",x["id"],"->",x["role"])
PY

echo "=== 3. APPLY ROSTER TO OPENCLAW ==="
python3 - <<'PY'
import json
from pathlib import Path

rp=Path("/home/ubuntu/Central/config/model-roster.json")
op=Path("/home/ubuntu/.openclaw/openclaw.json")
roster=json.loads(rp.read_text(encoding="utf-8"))
cfg=json.loads(op.read_text(encoding="utf-8"))

defaults=cfg.setdefault("agents",{}).setdefault("defaults",{})
models=defaults.setdefault("models",{})

# Keep only roster entries plus any explicitly unrelated models already present.
for group in ("groq","openrouter"):
    for item in roster[group]:
        models.setdefault(item["id"],{})

defaults["model"]={
    "primary":roster["policy"]["primary"],
    "fallbacks":roster["policy"]["fallback_order"]
}

# Ensure Groq custom catalog knows all three verified Groq models.
providers=cfg.setdefault("models",{}).setdefault("providers",{})
groq=providers.setdefault("groq",{})
groq["baseUrl"]="https://api.groq.com/openai/v1"
groq["api"]="openai-completions"
groq["apiKey"]="$"+"{GROQ_API_KEY}"
wanted=[
 {"id":"openai/gpt-oss-20b","name":"openai/gpt-oss-20b","contextWindow":131072,"contextTokens":32768,"maxTokens":8192},
 {"id":"qwen/qwen3.8-27b","name":"qwen/qwen3.8-27b","contextWindow":131072,"contextTokens":32768,"maxTokens":8192},
 {"id":"openai/gpt-oss-120b","name":"openai/gpt-oss-120b","contextWindow":131072,"contextTokens":32768,"maxTokens":8192},
]
groq["models"]=wanted

op.write_text(json.dumps(cfg,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("OPENCLAW_ROSTER_APPLIED")
print("primary=",defaults["model"]["primary"])
for i,m in enumerate(defaults["model"]["fallbacks"],1):
    print(f"fallback_{i}={m}")
PY

chown ubuntu:ubuntu "$OCFG" "$ROSTER"
chmod 600 "$OCFG"
chmod 644 "$ROSTER"

echo "=== 4. RESTART OPENCLAW ==="
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

echo "=== 5. VERIFY EFFECTIVE POLICY ==="
python3 - <<'PY'
import json
from pathlib import Path
cfg=json.loads(Path("/home/ubuntu/.openclaw/openclaw.json").read_text())
d=cfg["agents"]["defaults"]["model"]
print("primary="+d["primary"])
for i,m in enumerate(d.get("fallbacks",[]),1):
    print(f"fallback_{i}={m}")
PY

echo "=== 6. DIRECT PROVIDER SMOKES ==="
python3 - <<'PY'
import json, os, urllib.request
from pathlib import Path

def call(url,key,model):
    payload={"model":model,"messages":[{"role":"user","content":"Respondé exactamente OK"}],"max_tokens":24}
    req=urllib.request.Request(url,data=json.dumps(payload).encode(),headers={
      "Authorization":"Bearer "+key,
      "Content-Type":"application/json",
    },method="POST")
    with urllib.request.urlopen(req,timeout=45) as r:
        body=json.loads(r.read().decode())
    ans=((body.get("choices") or [{}])[0].get("message") or {}).get("content","").strip()
    return ans

groq=Path("/home/ubuntu/Claves/prov/groq.key").read_text().strip()
orouter=Path("/home/ubuntu/Claves/providers/openrouter.key").read_text().strip()
tests=[
 ("groq","https://api.groq.com/openai/v1/chat/completions",groq,"openai/gpt-oss-20b"),
 ("groq","https://api.groq.com/openai/v1/chat/completions",groq,"qwen/qwen3.8-27b"),
 ("groq","https://api.groq.com/openai/v1/chat/completions",groq,"openai/gpt-oss-120b"),
]
roster=json.loads(Path("/home/ubuntu/Central/config/model-roster.json").read_text())
ors=[x["id"].removeprefix("openrouter/") for x in roster["openrouter"] if x["id"]!="openrouter/free"]
if ors:
    tests.append(("openrouter","https://openrouter.ai/api/v1/chat/completions",orouter,ors[0]))

for provider,url,key,model in tests:
    try:
        ans=call(url,key,model)
        print(f"{provider} {model} => {ans[:80]}")
    except Exception as e:
        print(f"{provider} {model} => ERROR {type(e).__name__}: {e}")
PY

echo "backup=$BACKUP"
echo DUAL_MODEL_ROSTER_READY
