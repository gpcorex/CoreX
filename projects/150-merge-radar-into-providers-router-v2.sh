#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STATE=/home/ubuntu/Central/state
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/providers-router-v2-$STAMP

mkdir -p "$BACKUP" "$STATE"
for f in providers.py router.py cli.py radar.py BUILD_REPORT.json; do
  [ -e "$DEST/$f" ] && cp -a "$DEST/$f" "$BACKUP/$f"
done

echo "=== 1. PROVIDERS V2: DISCOVERY + CATALOG + HEALTH ==="
cat >"$DEST/providers.py" <<'PY'
from __future__ import annotations
import json, time, urllib.request, urllib.error
from pathlib import Path

class ProviderError(RuntimeError): pass

class OpenAICompatProvider:
    def __init__(self, name:str, base_url:str, api_key:str, timeout:int=60):
        self.name=name
        self.base_url=base_url.rstrip("/")
        self.api_key=api_key
        self.timeout=timeout

    def _request(self,path:str,payload:dict|None=None,method:str="GET"):
        data=None if payload is None else json.dumps(payload,ensure_ascii=False).encode()
        req=urllib.request.Request(
            self.base_url+path,
            data=data,
            method=method,
            headers={
                "Authorization":"Bearer "+self.api_key,
                "Content-Type":"application/json",
                "Accept":"application/json",
                "User-Agent":"Central-Native/2.0",
            },
        )
        started=time.monotonic()
        try:
            with urllib.request.urlopen(req,timeout=self.timeout) as r:
                body=json.loads(r.read().decode())
                return body, round((time.monotonic()-started)*1000)
        except urllib.error.HTTPError as e:
            body=e.read().decode("utf-8","replace")[-1500:]
            raise ProviderError(f"{self.name}:HTTP_{e.code}:{body}")
        except Exception as e:
            raise ProviderError(f"{self.name}:{type(e).__name__}:{e}")

    def list_models(self):
        out,lat=self._request("/models")
        return [x for x in out.get("data",[]) if isinstance(x,dict)],lat

    def chat(self,model:str,messages:list[dict],tools:list[dict]|None=None,
             max_tokens:int=1024,temperature:float=0.2):
        payload={"model":model,"messages":messages,"max_tokens":max_tokens,"temperature":temperature}
        if tools:
            payload["tools"]=tools
            payload["tool_choice"]="auto"
        out,_=self._request("/chat/completions",payload,"POST")
        return out

    def probe(self,model:str)->dict:
        started=time.monotonic()
        try:
            out=self.chat(model,[{"role":"user","content":"Respondé exactamente OK"}],max_tokens=16,temperature=0)
            ans=((out.get("choices") or [{}])[0].get("message") or {}).get("content","").strip()
            return {"ok":ans=="OK","latency_ms":round((time.monotonic()-started)*1000),"answer":ans[:40]}
        except Exception as e:
            return {"ok":False,"latency_ms":round((time.monotonic()-started)*1000),"error":str(e)[:300]}

def groq_provider(key:str,timeout:int=60):
    return OpenAICompatProvider("groq","https://api.groq.com/openai/v1",key,timeout)

def openrouter_provider(key:str,timeout:int=60):
    return OpenAICompatProvider("openrouter","https://openrouter.ai/api/v1",key,timeout)

# Central does not keep a separate Radar component. Discovery and health live here.
class ProviderRegistry:
    def __init__(self,groq_key:str,openrouter_key:str,state_path:str|Path):
        self.providers={
            "groq":groq_provider(groq_key,30),
            "openrouter":openrouter_provider(openrouter_key,30),
        }
        self.state_path=Path(state_path)
        self.state_path.parent.mkdir(parents=True,exist_ok=True)
        self.state=self._load()

    def _load(self):
        if self.state_path.is_file():
            try: return json.loads(self.state_path.read_text(encoding="utf-8"))
            except Exception: pass
        return {"version":2,"updated_at":0,"models":{},"capabilities":{},"metrics":{}}

    def save(self):
        self.state["updated_at"]=int(time.time())
        tmp=self.state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.state,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
        tmp.replace(self.state_path)

    def discover(self,provider_name:str|None=None)->dict:
        names=[provider_name] if provider_name else list(self.providers)
        result={}
        for name in names:
            p=self.providers[name]
            try:
                models,lat=p.list_models()
                ids=[m.get("id") for m in models if m.get("id")]
                self.state["models"][name]={"ok":True,"count":len(ids),"ids":ids,"latency_ms":lat,"checked_at":int(time.time())}
                result[name]=self.state["models"][name]
            except Exception as e:
                self.state["models"][name]={"ok":False,"count":0,"ids":[],"error":str(e),"checked_at":int(time.time())}
                result[name]=self.state["models"][name]
        self.save()
        return result

    def healthcheck(self,provider_name:str,model:str)->dict:
        p=self.providers[provider_name]
        r=p.probe(model)
        key=f"{provider_name}/{model}"
        m=self.state["metrics"].setdefault(key,{"success":0,"fail":0,"latency_ms":[],"compliance":1.0})
        if r["ok"]: m["success"]+=1
        else: m["fail"]+=1
        m["latency_ms"]=(m.get("latency_ms",[])+[r["latency_ms"]])[-20:]
        m["last_ok"]=bool(r["ok"]); m["last_checked_at"]=int(time.time())
        self.save()
        return r

    def record_result(self,model_ref:str,ok:bool,latency_ms:int|None=None,compliance:float|None=None):
        m=self.state["metrics"].setdefault(model_ref,{"success":0,"fail":0,"latency_ms":[],"compliance":1.0})
        m["success" if ok else "fail"]+=1
        if latency_ms is not None:
            m["latency_ms"]=(m.get("latency_ms",[])+[int(latency_ms)])[-20:]
        if compliance is not None:
            old=float(m.get("compliance",1.0))
            m["compliance"]=round(old*0.8+float(compliance)*0.2,4)
        m["last_ok"]=bool(ok); m["last_used_at"]=int(time.time())
        self.save()

    def set_candidates(self,capability:str,candidates:list[dict]):
        cleaned=[]
        for c in candidates[:3]:
            ref=str(c["ref"])
            provider=ref.split("/",1)[0]
            cleaned.append({
                "ref":ref,
                "provider":provider,
                "quality":float(c.get("quality",0.5)),
                "preferred":int(c.get("preferred",0)),
                "cost":float(c.get("cost",0)),
                "requirements":list(c.get("requirements",[])),
            })
        self.state["capabilities"][capability]=cleaned
        self.save()

    def get_candidates(self,capability:str)->list[dict]:
        return list(self.state.get("capabilities",{}).get(capability,[]))
PY
python3 -m py_compile "$DEST/providers.py"
echo PROVIDERS_V2_OK

echo "=== 2. ROUTER V2: PREFERENCES + DYNAMIC SCORE ==="
cat >"$DEST/router.py" <<'PY'
from __future__ import annotations
from statistics import mean

CAPABILITY_ALIASES={
    "programacion":"programacion",
    "codigo":"programacion",
    "coding":"programacion",
    "razonamiento":"razonamiento",
    "analisis":"razonamiento",
    "rapido":"rapido",
    "conversacion":"rapido",
    "vision":"vision",
    "voz":"voz",
    "stt":"voz",
    "contexto_largo":"contexto_largo",
}

def normalize_capability(name:str)->str:
    return CAPABILITY_ALIASES.get((name or "rapido").lower(),"rapido")

def _metrics_for(state:dict,ref:str)->dict:
    return (state.get("metrics") or {}).get(ref,{}) or {}

def score_candidate(c:dict,state:dict)->float:
    ref=c["ref"]
    m=_metrics_for(state,ref)

    # Hard rule for this system: paid candidates are not eligible.
    if float(c.get("cost",0))>0:
        return -1e9

    success=float(m.get("success",0))
    fail=float(m.get("fail",0))
    total=success+fail
    health=(success/total) if total else 0.85
    if m.get("last_ok") is False:
        health*=0.35

    latencies=m.get("latency_ms") or []
    latency=mean(latencies) if latencies else 5000
    latency_score=max(0.0,1.0-min(latency,30000)/30000)

    quality=float(c.get("quality",0.5))
    compliance=float(m.get("compliance",1.0))
    preference=min(max(float(c.get("preferred",0)),0),2)/2

    # Priorities: capability/quality, health, compliance, latency, initial preference.
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

def select(capability:str,registry)->list[dict]:
    cap=normalize_capability(capability)
    candidates=registry.get_candidates(cap)
    if not candidates and cap!="rapido":
        candidates=registry.get_candidates("rapido")
    return rank_candidates(candidates,registry.state)

# Backward compatibility for current CLI/other callers.
def build_chain(roster:dict,role:str="rapido")->list[str]:
    policy=roster.get("policy",{}) if isinstance(roster,dict) else {}
    out=[]
    primary=policy.get("primary")
    if primary: out.append(primary)
    for x in policy.get("fallback_order") or []:
        if x and x not in out: out.append(x)
    return out

def provider_for(model_ref:str)->str:
    return model_ref.split("/",1)[0]
PY
python3 -m py_compile "$DEST/router.py"
echo ROUTER_V2_OK

echo "=== 3. INITIAL 3-CANDIDATE CATALOG ==="
PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry

s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")

# Initial known-good pool. Discovery can later replace candidates on demand.
r.set_candidates("programacion",[
  {"ref":"groq/qwen/qwen3.8-27b","quality":0.92,"preferred":2,"cost":0,"requirements":["tools"]},
  {"ref":"groq/openai/gpt-oss-120b","quality":0.95,"preferred":1,"cost":0,"requirements":["tools"]},
  {"ref":"groq/openai/gpt-oss-20b","quality":0.82,"preferred":0,"cost":0,"requirements":["tools"]},
])
r.set_candidates("razonamiento",[
  {"ref":"groq/openai/gpt-oss-120b","quality":0.96,"preferred":2,"cost":0},
  {"ref":"groq/qwen/qwen3.8-27b","quality":0.90,"preferred":1,"cost":0},
  {"ref":"groq/openai/gpt-oss-20b","quality":0.80,"preferred":0,"cost":0},
])
r.set_candidates("rapido",[
  {"ref":"groq/openai/gpt-oss-20b","quality":0.82,"preferred":2,"cost":0},
  {"ref":"groq/qwen/qwen3.8-27b","quality":0.90,"preferred":1,"cost":0},
  {"ref":"groq/openai/gpt-oss-120b","quality":0.96,"preferred":0,"cost":0},
])
print("PROVIDER_CATALOG_OK")
PY

echo "=== 4. REMOVE RADAR AS INDEPENDENT COMPONENT ==="
rm -f "$DEST/radar.py"
echo RADAR_COMPONENT_REMOVED

echo "=== 5. TEST ROUTER SCORING ==="
cat >"$DEST/tests/test_router_v2.py" <<'PY'
import tempfile, unittest
from router import rank_candidates

class RouterV2Tests(unittest.TestCase):
    def test_failure_demotes_candidate(self):
        c=[
          {"ref":"groq/a","quality":0.9,"preferred":2,"cost":0},
          {"ref":"groq/b","quality":0.8,"preferred":1,"cost":0},
        ]
        state={"metrics":{
          "groq/a":{"success":1,"fail":5,"last_ok":False,"latency_ms":[20000],"compliance":0.5},
          "groq/b":{"success":5,"fail":0,"last_ok":True,"latency_ms":[2000],"compliance":1.0},
        }}
        self.assertEqual(rank_candidates(c,state)[0]["ref"],"groq/b")

    def test_paid_is_rejected(self):
        c=[{"ref":"x/paid","quality":1,"preferred":2,"cost":1}]
        self.assertLess(rank_candidates(c,{"metrics":{}})[0]["score"],0)

if __name__=="__main__": unittest.main()
PY

PYTHONPATH="$DEST" python3 -m unittest "$DEST/tests/test_router_v2.py" -v
echo ROUTER_V2_TESTS_OK

echo "=== 6. REAL PROVIDER DISCOVERY ON DEMAND ==="
PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
out=r.discover()
assert out["groq"]["ok"] and out["groq"]["count"]>0,out["groq"]
assert out["openrouter"]["ok"] and out["openrouter"]["count"]>0,out["openrouter"]
print("PROVIDERS_DISCOVERY_OK","groq="+str(out["groq"]["count"]),"openrouter="+str(out["openrouter"]["count"]))
PY

echo "=== 7. REAL HEALTHCHECK OF PROGRAMMING CANDIDATES ==="
PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
from router import select

s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
for c in r.get_candidates("programacion"):
    ref=c["ref"]
    provider,model=ref.split("/",1)
    res=r.healthcheck(provider,model)
    print(ref,"ok="+str(res["ok"]),"latency_ms="+str(res["latency_ms"]))
ranked=select("programacion",r)
assert ranked and ranked[0]["score"]>=0,ranked
print("PROGRAMMING_RANKING_OK")
for i,c in enumerate(ranked,1):
    print(i,c["ref"],"score="+str(c["score"]))
PY

echo "=== 8. REGRESSION: CENTRAL NATIVE STILL WORKS ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá providers-router-v2.txt con el texto PROVIDERS_ROUTER_V2_OK, leelo y verificá que coincida exactamente.","source":"chat","project":"Central","conversation_id":"providers-router-v2"}' \
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
print("CENTRAL_NATIVE_REGRESSION_OK")
PY
grep -qx 'PROVIDERS_ROUTER_V2_OK' "/home/ubuntu/Central/work/$JOB/providers-router-v2.txt"

echo "=== 9. BUILD REPORT ==="
cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "providers-router-v2",
  "radar_component": "removed",
  "provider_discovery": "on-demand",
  "candidate_limit_per_capability": 3,
  "router_dynamic_scoring": true,
  "periodic_refresh": false,
  "tests": "passed",
  "active": true
}
EOF
chown -R ubuntu:ubuntu "$DEST" "$STATE/providers.json"

echo PROVIDERS_ROUTER_V2_READY
echo "state=/home/ubuntu/Central/state/providers.json"
echo "backup=$BACKUP"
echo "NOTE=No periodic timer installed."
