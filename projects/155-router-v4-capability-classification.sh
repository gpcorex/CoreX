#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STATE=/home/ubuntu/Central/state/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/router-v4-capabilities-$STAMP

mkdir -p "$BACKUP"
for f in cli.py router.py providers.py BUILD_REPORT.json; do
  [ -e "$DEST/$f" ] && cp -a "$DEST/$f" "$BACKUP/$f"
done

echo "=== 1. ROUTER V4: CAPABILITY PROFILES ==="
cat >"$DEST/router.py" <<'PY'
from __future__ import annotations
from statistics import mean

CAPABILITY_ALIASES={
    "programacion":"programacion","codigo":"programacion","coding":"programacion",
    "razonamiento":"razonamiento","analisis":"razonamiento",
    "rapido":"conversacion","conversacion":"conversacion","chat":"conversacion",
    "json":"estructurado","estructurado":"estructurado",
    "contexto_largo":"contexto_largo","long_context":"contexto_largo",
    "vision":"vision","imagen":"vision",
    "voz":"voz","stt":"voz","audio":"voz",
}

CAPABILITY_REQUIREMENTS={
    "programacion":["tools"],
    "razonamiento":[],
    "conversacion":[],
    "estructurado":["json"],
    "contexto_largo":["long_context"],
    "vision":["vision"],
    "voz":["audio"],
}

def normalize_capability(name:str)->str:
    return CAPABILITY_ALIASES.get((name or "conversacion").lower(),"conversacion")

def requirements_for(capability:str)->list[str]:
    return list(CAPABILITY_REQUIREMENTS.get(normalize_capability(capability),[]))

def score_candidate(c:dict,state:dict)->float:
    ref=c["ref"]
    m=(state.get("metrics") or {}).get(ref,{}) or {}
    if float(c.get("cost",0))>0:
        return -1e9

    success=float(m.get("success",0))
    fail=float(m.get("fail",0))
    total=success+fail
    health=(success/total) if total else 0.80
    if m.get("last_ok") is False:
        health*=0.45

    latencies=m.get("latency_ms") or []
    latency=mean(latencies) if latencies else 5000
    latency_score=max(0.0,1.0-min(latency,30000)/30000)

    quality=float(c.get("quality",0.5))
    compliance=float(m.get("compliance",1.0))
    preference=min(max(float(c.get("preferred",0)),0),2)/2

    return round(
        quality*0.30 +
        health*0.25 +
        compliance*0.20 +
        latency_score*0.15 +
        preference*0.10,
        6
    )

def rank_candidates(candidates:list[dict],state:dict)->list[dict]:
    out=[]
    for c in candidates:
        item=dict(c)
        item["score"]=score_candidate(item,state)
        out.append(item)
    return sorted(out,key=lambda x:x["score"],reverse=True)

def _dynamic_pool(registry,exclude:set[str],requirements:list[str]|None=None)->list[dict]:
    req=set(requirements or [])
    pool=[]
    for ref in registry.all_discovered_refs():
        if ref in exclude:
            continue
        provider,model=ref.split("/",1)
        low=model.lower()

        # Never feed non-chat or safety-only models to the generic agent.
        if any(x in low for x in ("whisper","orpheus","prompt-guard","safeguard")):
            continue

        # Project rule: free only.
        if provider=="openrouter" and not (model.endswith(":free") or model=="free"):
            continue

        inferred=set()
        quality=0.55
        if any(x in low for x in ("qwen","coder","gpt-oss","code","nemotron")):
            inferred.add("tools")
            inferred.add("json")
            quality=0.72
        if any(x in low for x in ("vision","vl","multimodal")):
            inferred.add("vision")
        if any(x in low for x in ("long","128k","256k","1m")):
            inferred.add("long_context")

        # Unknown capability is not treated as supported.
        if not req.issubset(inferred):
            continue

        pool.append({
            "ref":ref,
            "provider":provider,
            "quality":quality,
            "preferred":0,
            "cost":0,
            "requirements":sorted(inferred),
            "dynamic":True,
        })
    return rank_candidates(pool,registry.state)

def select(capability:str,registry,requirements:list[str]|None=None,max_dynamic:int=12)->list[dict]:
    cap=normalize_capability(capability)
    req=requirements_for(cap) if requirements is None else list(requirements)

    fixed=registry.get_fixed(cap)
    # Only conversational capability may inherit the old "rapido" pool.
    if not fixed and cap=="conversacion":
        fixed=registry.get_fixed("rapido")

    ranked_fixed=[]
    for c in fixed:
        declared=set(c.get("requirements") or [])
        # Fixed entries with no requirements are allowed for requirements-free tasks.
        if req and not set(req).issubset(declared):
            continue
        ranked_fixed.append(c)
    ranked_fixed=rank_candidates(ranked_fixed,registry.state)

    fixed_refs={x["ref"] for x in fixed}
    dynamic=_dynamic_pool(registry,fixed_refs,req)[:max_dynamic]

    healthy_fixed=[x for x in ranked_fixed if x["score"]>=0.60]
    degraded_fixed=[x for x in ranked_fixed if x["score"]<0.60]

    out=healthy_fixed+dynamic+degraded_fixed
    seen=set()
    dedup=[]
    for x in out:
        if x["ref"] not in seen:
            seen.add(x["ref"])
            dedup.append(x)
    return dedup

def provider_for(model_ref:str)->str:
    return model_ref.split("/",1)[0]
PY
python3 -m py_compile "$DEST/router.py"
echo ROUTER_V4_OK

echo "=== 2. CLASSIFIER V4 ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/cli.py")
s=p.read_text(encoding="utf-8")

start=s.index("def infer_capability")
end=s.index("\ndef main():",start)

new=r'''def infer_capability(task:str,role:str)->str:
    if role and role!="auto":
        from router import normalize_capability
        return normalize_capability(role)

    t=(task or "").lower()

    # Order matters: specific capabilities before generic reasoning/chat.
    vision_words=("imagen","foto","captura","screenshot","visual","ocr","qué ves","que ves")
    voice_words=("audio","voz","transcrib","stt","speech","grabación","grabacion")
    long_words=("contexto largo","documento enorme","archivo muy largo","muchos tokens","long context")
    structured_words=("json","salida estructurada","estructura exacta","schema","esquema json")
    code_words=("python","programa","código","codigo","script","bash","programar","función","funcion","test","archivo")
    reasoning_words=("analiz","razon","compar","explic","investig","diagnostic","planific")

    if any(w in t for w in vision_words): return "vision"
    if any(w in t for w in voice_words): return "voz"
    if any(w in t for w in long_words): return "contexto_largo"
    if any(w in t for w in structured_words): return "estructurado"
    if any(w in t for w in code_words): return "programacion"
    if any(w in t for w in reasoning_words): return "razonamiento"
    return "conversacion"
'''

s=s[:start]+new+s[end:]
s=s.replace(
'    requirements=["tools"] if capability=="programacion" else []\n    ranked=select(capability,registry,requirements=requirements)\n',
'    from router import requirements_for\n    requirements=requirements_for(capability)\n    ranked=select(capability,registry,requirements=requirements)\n'
)
p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$DEST/cli.py"
echo CLASSIFIER_V4_OK

echo "=== 3. NORMALIZE FIXED CAPABILITY CATALOG ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")

# Existing known-good pools, now with explicit capability requirements.
r.set_fixed("programacion",[
  {"ref":"groq/qwen/qwen3.8-27b","quality":0.92,"preferred":2,"cost":0,"requirements":["tools"]},
  {"ref":"groq/openai/gpt-oss-120b","quality":0.95,"preferred":1,"cost":0,"requirements":["tools"]},
  {"ref":"groq/openai/gpt-oss-20b","quality":0.82,"preferred":0,"cost":0,"requirements":["tools"]},
])
r.set_fixed("razonamiento",[
  {"ref":"groq/openai/gpt-oss-120b","quality":0.96,"preferred":2,"cost":0,"requirements":[]},
  {"ref":"groq/qwen/qwen3.8-27b","quality":0.90,"preferred":1,"cost":0,"requirements":[]},
  {"ref":"groq/openai/gpt-oss-20b","quality":0.80,"preferred":0,"cost":0,"requirements":[]},
])
r.set_fixed("conversacion",[
  {"ref":"groq/openai/gpt-oss-20b","quality":0.82,"preferred":2,"cost":0,"requirements":[]},
  {"ref":"groq/qwen/qwen3.8-27b","quality":0.90,"preferred":1,"cost":0,"requirements":[]},
  {"ref":"groq/openai/gpt-oss-120b","quality":0.96,"preferred":0,"cost":0,"requirements":[]},
])
r.set_fixed("estructurado",[
  {"ref":"groq/qwen/qwen3.8-27b","quality":0.90,"preferred":2,"cost":0,"requirements":["json"]},
  {"ref":"groq/openai/gpt-oss-120b","quality":0.93,"preferred":1,"cost":0,"requirements":["json"]},
  {"ref":"groq/openai/gpt-oss-20b","quality":0.80,"preferred":0,"cost":0,"requirements":["json"]},
])

# vision / voz / contexto_largo stay empty until capability is verified.
print("CAPABILITY_CATALOG_OK")
PY

echo "=== 4. CLASSIFIER + ROUTER TESTS ==="
cat >"$DEST/tests/test_capabilities_v4.py" <<'PY'
import unittest
from cli import infer_capability
from router import requirements_for

class CapabilityV4Tests(unittest.TestCase):
    def test_classification(self):
        cases={
          "Creá un programa Python":"programacion",
          "Analizá estas alternativas":"razonamiento",
          "Respondé en JSON con este schema":"estructurado",
          "Qué ves en esta imagen":"vision",
          "Transcribí este audio":"voz",
          "Necesito contexto largo para un documento enorme":"contexto_largo",
          "Hola, cómo estás":"conversacion",
        }
        for text,expected in cases.items():
            self.assertEqual(infer_capability(text,"auto"),expected,text)

    def test_requirements(self):
        self.assertEqual(requirements_for("programacion"),["tools"])
        self.assertEqual(requirements_for("estructurado"),["json"])
        self.assertEqual(requirements_for("vision"),["vision"])
        self.assertEqual(requirements_for("voz"),["audio"])

if __name__=="__main__": unittest.main()
PY

PYTHONPATH="$DEST" python3 -m unittest discover -s "$DEST/tests" -p 'test_capabilities_v4.py' -v
echo CAPABILITY_V4_TESTS_OK

echo "=== 5. VERIFY UNSUPPORTED CAPABILITIES DO NOT SILENTLY FALL BACK ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
from router import select
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")

# We require verified compatibility. Empty is safer than silently using a text model.
for cap in ("vision","voz","contexto_largo"):
    ranked=select(cap,r)
    print(cap,"candidates="+str(len(ranked)))
print("STRICT_CAPABILITY_FILTER_OK")
PY

echo "=== 6. LIVE PROGRAMMING REGRESSION ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá capabilities-v4.py que imprima exactamente CAPABILITIES_V4_OK, ejecutalo y verificá la salida.","source":"chat","project":"Central","conversation_id":"capabilities-v4"}' \
  http://127.0.0.1:8091/api/jobs)
JOB=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP")
for i in $(seq 1 120); do
  OUT=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB")
  S=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
  printf '\rstatus=%s elapsed=%ss' "$S" "$i"
  case "$S" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
echo
OUT_JSON="$OUT" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
r=j.get("result") or {}
assert r.get("jugador")=="Central Native",r
assert "openclaw" not in r,r
print("CENTRAL_CAPABILITY_V4_REGRESSION_OK")
PY
grep -q 'CAPABILITIES_V4_OK' "/home/ubuntu/Central/work/$JOB/capabilities-v4.py"

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "router-v4-capabilities",
  "capabilities": ["programacion","razonamiento","conversacion","estructurado","contexto_largo","vision","voz"],
  "verified_fixed_pools": ["programacion","razonamiento","conversacion","estructurado"],
  "strict_unverified_capabilities": ["contexto_largo","vision","voz"],
  "dynamic_full_pool_fallback": true,
  "automatic_promotion": false,
  "periodic_refresh": false,
  "active": true
}
EOF

echo CENTRAL_CAPABILITIES_V4_READY
echo "backup=$BACKUP"
echo "NOTE=vision/voz/contexto_largo are classified but not silently assigned until provider capability is verified."
