#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STATE=/home/ubuntu/Central/state/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/router-v4-capability-strict-$STAMP

mkdir -p "$BACKUP"
cp -a "$DEST/providers.py" "$DEST/router.py" "$DEST/cli.py" "$BACKUP/" 2>/dev/null || true

echo "=== 1. ADD VERIFIED CAPABILITIES TO PROVIDERS ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/providers.py")
s=p.read_text(encoding="utf-8")

anchor='''    def promotion_candidates(self,capability:str)->list[dict]:
        return list((self.state.get("promotions") or {}).get(capability,[]))
'''
insert='''    def set_verified_capabilities(self,model_ref:str,capabilities:list[str]):
        caps=self.state.setdefault("verified_capabilities",{})
        caps[model_ref]=sorted(set(str(x) for x in capabilities))
        self.save()

    def verified_capabilities(self,model_ref:str)->set[str]:
        return set((self.state.get("verified_capabilities") or {}).get(model_ref,[]))

    def infer_metadata_capabilities(self,model_ref:str)->set[str]:
        provider,model=model_ref.split("/",1)
        info=(self.state.get("models") or {}).get(provider,{})
        meta=(info.get("meta") or {}).get(model,{}) or {}
        caps=set()

        supported=set(meta.get("supported_parameters") or [])
        if "tools" in supported or "tool_choice" in supported:
            caps.add("tools")
        if "response_format" in supported or "structured_outputs" in supported:
            caps.add("json")

        arch=meta.get("architecture") or {}
        modalities=set(arch.get("input_modalities") or meta.get("input_modalities") or [])
        if "image" in modalities:
            caps.add("vision")
        if "audio" in modalities:
            caps.add("audio")

        try:
            ctx=int(meta.get("context_length") or 0)
            if ctx>=100000:
                caps.add("long_context")
        except Exception:
            pass
        return caps

    def capabilities_for(self,model_ref:str)->set[str]:
        return self.verified_capabilities(model_ref) | self.infer_metadata_capabilities(model_ref)

    def promotion_candidates(self,capability:str)->list[dict]:
        return list((self.state.get("promotions") or {}).get(capability,[]))
'''
if anchor not in s:
    raise SystemExit("PROVIDERS_CAPABILITY_ANCHOR_NOT_FOUND")
p.write_text(s.replace(anchor,insert,1),encoding="utf-8")
PY
python3 -m py_compile "$DEST/providers.py"
echo PROVIDERS_VERIFIED_CAPABILITIES_OK

echo "=== 2. MAKE DYNAMIC FALLBACK STRICT ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/router.py")
s=p.read_text(encoding="utf-8")
start=s.index("def _dynamic_pool(")
end=s.index("\ndef select(",start)
new=r'''def _dynamic_pool(registry,exclude:set[str],requirements:list[str]|None=None)->list[dict]:
    req=set(requirements or [])
    pool=[]
    for ref in registry.all_discovered_refs():
        if ref in exclude:
            continue
        provider,model=ref.split("/",1)
        low=model.lower()

        if any(x in low for x in ("whisper","orpheus","prompt-guard","safeguard")):
            continue

        # Project rule: OpenRouter candidates must be free.
        if provider=="openrouter" and not (model.endswith(":free") or model=="free"):
            continue

        # Critical rule: never infer a capability from a model name.
        # Requirements must be verified explicitly or supported by provider metadata.
        caps=registry.capabilities_for(ref)
        if not req.issubset(caps):
            continue

        m=(registry.state.get("metrics") or {}).get(ref,{})
        success=float(m.get("success",0)); fail=float(m.get("fail",0))
        total=success+fail
        observed=(success/total) if total else 0.0
        quality=0.55 + min(0.20, observed*0.20)

        pool.append({
            "ref":ref,
            "provider":provider,
            "quality":quality,
            "preferred":0,
            "cost":0,
            "requirements":sorted(caps),
            "dynamic":True,
        })
    return rank_candidates(pool,registry.state)
'''
p.write_text(s[:start]+new+s[end:],encoding="utf-8")
PY
python3 -m py_compile "$DEST/router.py"
echo ROUTER_STRICT_DYNAMIC_CAPABILITIES_OK

echo "=== 3. SEED ONLY ACTUALLY VERIFIED FIXED CAPABILITIES ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")

# These three have already completed real tool-calling programming tests in Central.
for ref in (
    "groq/qwen/qwen3.8-27b",
    "groq/openai/gpt-oss-120b",
    "groq/openai/gpt-oss-20b",
):
    r.set_verified_capabilities(ref,["tools","json"])

print("FIXED_CAPABILITIES_SEEDED_OK")
PY

echo "=== 4. STRICT CAPABILITY TEST ==="
cat >"$DEST/tests/test_capability_strict_v4.py" <<'PY'
import unittest
from router import select

class FakeRegistry:
    def __init__(self):
        self.state={"metrics":{}}
    def get_fixed(self,cap): return []
    def all_discovered_refs(self):
        return ["openrouter/fake-vision-name:free","openrouter/actually-vision:free"]
    def capabilities_for(self,ref):
        if ref.endswith("actually-vision:free"): return {"vision"}
        return set()

class StrictCapabilityTests(unittest.TestCase):
    def test_name_does_not_grant_vision(self):
        refs=[x["ref"] for x in select("vision",FakeRegistry())]
        self.assertNotIn("openrouter/fake-vision-name:free",refs)
        self.assertIn("openrouter/actually-vision:free",refs)

if __name__=="__main__": unittest.main()
PY
PYTHONPATH="$DEST" python3 -m unittest discover -s "$DEST/tests" -p 'test_capability_strict_v4.py' -v
echo STRICT_CAPABILITY_TEST_OK

echo "=== 5. REAL CAPABILITY COUNTS ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
from router import select
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
for cap in ("programacion","vision","voz","contexto_largo"):
    xs=select(cap,r)
    print(cap,"candidates="+str(len(xs)))
assert len(select("programacion",r))>=1
print("REAL_STRICT_CAPABILITY_FILTER_OK")
PY

echo "=== 6. PROGRAMMING REGRESSION ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá strict-capability.py que imprima exactamente STRICT_CAPABILITY_OK, ejecutalo y verificá la salida.","source":"chat","project":"Central","conversation_id":"strict-capability"}' \
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
print("CENTRAL_STRICT_CAPABILITY_REGRESSION_OK")
PY
grep -q 'STRICT_CAPABILITY_OK' "/home/ubuntu/Central/work/$JOB/strict-capability.py"

echo CENTRAL_CAPABILITY_STRICT_READY
echo "backup=$BACKUP"
