#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STATE=/home/ubuntu/Central/state/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/router-v3-dynamic-pool-$STAMP

mkdir -p "$BACKUP"
for f in providers.py router.py cli.py BUILD_REPORT.json; do
  [ -e "$DEST/$f" ] && cp -a "$DEST/$f" "$BACKUP/$f"
done

echo "=== 1. PROVIDERS V3: FIXED + FULL POOL + HISTORY ==="
cat >"$DEST/providers.py" <<'PY'
from __future__ import annotations
import json, time, urllib.request, urllib.error
from pathlib import Path

class ProviderError(RuntimeError): pass

class OpenAICompatProvider:
    def __init__(self,name:str,base_url:str,api_key:str,timeout:int=60):
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
                "User-Agent":"Central-Native/3.0",
            },
        )
        started=time.monotonic()
        try:
            with urllib.request.urlopen(req,timeout=self.timeout) as r:
                body=json.loads(r.read().decode())
                return body,round((time.monotonic()-started)*1000)
        except urllib.error.HTTPError as e:
            body=e.read().decode("utf-8","replace")[-1500:]
            raise ProviderError(f"{self.name}:HTTP_{e.code}:{body}")
        except Exception as e:
            raise ProviderError(f"{self.name}:{type(e).__name__}:{e}")

    def list_models(self):
        out,lat=self._request("/models")
        return [x for x in out.get("data",[]) if isinstance(x,dict)],lat

    def chat(self,model:str,messages:list[dict],tools:list[dict]|None=None,max_tokens:int=1024,temperature:float=0.2):
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
            try:
                x=json.loads(self.state_path.read_text(encoding="utf-8"))
                x.setdefault("version",3)
                x.setdefault("models",{})
                x.setdefault("capabilities",{})
                x.setdefault("metrics",{})
                x.setdefault("promotions",{})
                return x
            except Exception:
                pass
        return {"version":3,"updated_at":0,"models":{},"capabilities":{},"metrics":{},"promotions":{}}

    def save(self):
        self.state["version"]=3
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
                meta={m.get("id"):m for m in models if m.get("id")}
                self.state["models"][name]={
                    "ok":True,"count":len(ids),"ids":ids,"meta":meta,
                    "latency_ms":lat,"checked_at":int(time.time())
                }
            except Exception as e:
                self.state["models"][name]={
                    "ok":False,"count":0,"ids":[],"meta":{},"error":str(e),"checked_at":int(time.time())
                }
            result[name]=self.state["models"][name]
        self.save()
        return result

    def record_result(self,model_ref:str,ok:bool,latency_ms:int|None=None,compliance:float|None=None,capability:str|None=None):
        m=self.state["metrics"].setdefault(model_ref,{
            "success":0,"fail":0,"latency_ms":[],"compliance":1.0,
            "by_capability":{}
        })
        m["success" if ok else "fail"]+=1
        if latency_ms is not None:
            m["latency_ms"]=(m.get("latency_ms",[])+[int(latency_ms)])[-30:]
        if compliance is not None:
            old=float(m.get("compliance",1.0))
            m["compliance"]=round(old*0.8+float(compliance)*0.2,4)
        m["last_ok"]=bool(ok)
        m["last_used_at"]=int(time.time())

        if capability:
            c=m.setdefault("by_capability",{}).setdefault(capability,{"success":0,"fail":0})
            c["success" if ok else "fail"]+=1

        self._update_promotions(capability)
        self.save()

    def set_fixed(self,capability:str,candidates:list[dict]):
        cleaned=[]
        for c in candidates[:3]:
            ref=str(c["ref"])
            cleaned.append({
                "ref":ref,
                "provider":ref.split("/",1)[0],
                "quality":float(c.get("quality",0.5)),
                "preferred":int(c.get("preferred",0)),
                "cost":float(c.get("cost",0)),
                "requirements":list(c.get("requirements",[])),
            })
        self.state["capabilities"][capability]=cleaned
        self.save()

    def get_fixed(self,capability:str)->list[dict]:
        return list(self.state.get("capabilities",{}).get(capability,[]))

    def all_discovered_refs(self)->list[str]:
        refs=[]
        for provider,info in (self.state.get("models") or {}).items():
            for mid in info.get("ids") or []:
                ref=f"{provider}/{mid}"
                if ref not in refs:
                    refs.append(ref)
        return refs

    def _update_promotions(self,capability:str|None):
        if not capability:
            return
        fixed={x["ref"] for x in self.get_fixed(capability)}
        candidates=[]
        for ref,m in (self.state.get("metrics") or {}).items():
            if ref in fixed:
                continue
            bc=(m.get("by_capability") or {}).get(capability) or {}
            success=int(bc.get("success",0))
            fail=int(bc.get("fail",0))
            total=success+fail
            if total<3:
                continue
            rate=success/total if total else 0
            lat=m.get("latency_ms") or []
            avg=(sum(lat)/len(lat)) if lat else 999999
            if success>=3 and rate>=0.8 and float(m.get("compliance",1.0))>=0.9:
                candidates.append({
                    "ref":ref,
                    "success":success,
                    "fail":fail,
                    "success_rate":round(rate,4),
                    "avg_latency_ms":round(avg),
                    "compliance":float(m.get("compliance",1.0)),
                    "status":"CANDIDATO_A_FIJO",
                })
        candidates.sort(key=lambda x:(x["success_rate"],x["success"],-x["avg_latency_ms"]),reverse=True)
        self.state["promotions"][capability]=candidates[:10]

    def promotion_candidates(self,capability:str)->list[dict]:
        return list((self.state.get("promotions") or {}).get(capability,[]))
PY
python3 -m py_compile "$DEST/providers.py"
echo PROVIDERS_V3_OK

echo "=== 2. ROUTER V3: 3 FIXED + DYNAMIC FULL POOL ==="
cat >"$DEST/router.py" <<'PY'
from __future__ import annotations
from statistics import mean

CAPABILITY_ALIASES={
    "programacion":"programacion","codigo":"programacion","coding":"programacion",
    "razonamiento":"razonamiento","analisis":"razonamiento",
    "rapido":"rapido","conversacion":"rapido",
    "vision":"vision","voz":"voz","stt":"voz","contexto_largo":"contexto_largo",
}

def normalize_capability(name:str)->str:
    return CAPABILITY_ALIASES.get((name or "rapido").lower(),"rapido")

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
    # Conservative defaults: discovered zero-cost refs only.
    # Requirements are filters, not hardcoded provider bindings.
    req=set(requirements or [])
    pool=[]
    for ref in registry.all_discovered_refs():
        if ref in exclude:
            continue
        provider,model=ref.split("/",1)

        # Skip obvious non-chat/audio/safety-only entries for generic fallback.
        low=model.lower()
        blocked=("whisper","orpheus","prompt-guard","safeguard")
        if any(x in low for x in blocked):
            continue

        # OpenRouter free-only rule.
        if provider=="openrouter" and not (model.endswith(":free") or model=="free"):
            continue

        # Tool-capable capability is learned progressively; for programming,
        # prefer names already known to be suitable before trying unknowns.
        quality=0.55
        if any(x in low for x in ("qwen","coder","gpt-oss","code","nemotron")):
            quality=0.72
        if "tools" in req and quality<0.70:
            continue

        pool.append({
            "ref":ref,
            "provider":provider,
            "quality":quality,
            "preferred":0,
            "cost":0,
            "requirements":list(req),
            "dynamic":True,
        })
    return rank_candidates(pool,registry.state)

def select(capability:str,registry,requirements:list[str]|None=None,max_dynamic:int=12)->list[dict]:
    cap=normalize_capability(capability)
    fixed=registry.get_fixed(cap)
    if not fixed and cap!="rapido":
        fixed=registry.get_fixed("rapido")

    ranked_fixed=rank_candidates(fixed,registry.state)
    fixed_refs={x["ref"] for x in fixed}
    dynamic=_dynamic_pool(registry,fixed_refs,requirements)[:max_dynamic]

    # Fixed candidates remain first unless their score has degraded badly.
    healthy_fixed=[x for x in ranked_fixed if x["score"]>=0.60]
    degraded_fixed=[x for x in ranked_fixed if x["score"]<0.60]

    out=healthy_fixed+dynamic+degraded_fixed
    seen=set()
    dedup=[]
    for x in out:
        if x["ref"] not in seen:
            seen.add(x["ref"]); dedup.append(x)
    return dedup

def provider_for(model_ref:str)->str:
    return model_ref.split("/",1)[0]
PY
python3 -m py_compile "$DEST/router.py"
echo ROUTER_V3_OK

echo "=== 3. UPDATE CLI FOR REQUIREMENTS + HISTORY ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/cli.py")
s=p.read_text(encoding="utf-8")
s=s.replace(
'    ranked=select(capability,registry)\n',
'    requirements=["tools"] if capability=="programacion" else []\n    ranked=select(capability,registry,requirements=requirements)\n'
)
s=s.replace(
'            registry.record_result(ref,True,latency_ms,1.0)\n',
'            registry.record_result(ref,True,latency_ms,1.0,capability)\n'
)
s=s.replace(
'            registry.record_result(ref,False,latency_ms,0.0)\n',
'            registry.record_result(ref,False,latency_ms,0.0,capability)\n'
)
p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$DEST/cli.py"
echo CLI_ROUTER_V3_OK

echo "=== 4. ENSURE DISCOVERY CATALOG EXISTS ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
out=r.discover()
assert out["groq"]["ok"] and out["groq"]["count"]>0
assert out["openrouter"]["ok"] and out["openrouter"]["count"]>0
print("FULL_PROVIDER_POOL_OK",sum(x["count"] for x in out.values()))
PY

echo "=== 5. TEST FIXED + DYNAMIC FALLBACK ORDER ==="
cat >"$DEST/tests/test_router_v3.py" <<'PY'
import unittest
from router import select

class FakeRegistry:
    def __init__(self):
        self.state={"metrics":{
          "groq/fixed1":{"success":5,"fail":0,"last_ok":True,"latency_ms":[500],"compliance":1.0},
          "groq/fixed2":{"success":0,"fail":5,"last_ok":False,"latency_ms":[20000],"compliance":0.4},
          "groq/fixed3":{"success":0,"fail":4,"last_ok":False,"latency_ms":[18000],"compliance":0.4},
          "openrouter/qwen-coder:free":{"success":4,"fail":0,"last_ok":True,"latency_ms":[1000],"compliance":1.0},
        }}
    def get_fixed(self,cap):
        return [
          {"ref":"groq/fixed1","quality":.9,"preferred":2,"cost":0,"requirements":["tools"]},
          {"ref":"groq/fixed2","quality":.9,"preferred":1,"cost":0,"requirements":["tools"]},
          {"ref":"groq/fixed3","quality":.9,"preferred":0,"cost":0,"requirements":["tools"]},
        ]
    def all_discovered_refs(self):
        return ["groq/fixed1","groq/fixed2","groq/fixed3","openrouter/qwen-coder:free"]

class RouterV3Tests(unittest.TestCase):
    def test_dynamic_enters_before_degraded_fixed(self):
        r=select("programacion",FakeRegistry(),requirements=["tools"])
        refs=[x["ref"] for x in r]
        self.assertEqual(refs[0],"groq/fixed1")
        self.assertLess(refs.index("openrouter/qwen-coder:free"),refs.index("groq/fixed2"))

if __name__=="__main__": unittest.main()
PY

PYTHONPATH="$DEST" python3 -m unittest discover -s "$DEST/tests" -p 'test_router_v3.py' -v
echo ROUTER_V3_TESTS_OK

echo "=== 6. LIVE PROGRAMMING REGRESSION ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá router-v3-live.py que imprima exactamente ROUTER_V3_LIVE_OK, ejecutalo y verificá la salida.","source":"chat","project":"Central","conversation_id":"router-v3-live"}' \
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
echo "$OUT"
OUT_JSON="$OUT" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
r=j.get("result") or {}
assert r.get("jugador")=="Central Native",r
assert "openclaw" not in r,r
print("CENTRAL_ROUTER_V3_LIVE_OK")
PY

grep -q 'ROUTER_V3_LIVE_OK' "/home/ubuntu/Central/work/$JOB/router-v3-live.py"

echo "=== 7. SHOW PROMOTION CANDIDATES ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
c=r.promotion_candidates("programacion")
print("PROMOTION_CANDIDATES_COUNT="+str(len(c)))
for x in c:
    print(x["ref"],x["status"],"success_rate="+str(x["success_rate"]))
print("PROMOTION_HISTORY_READY")
PY

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "router-v3-dynamic-pool",
  "fixed_per_capability": 3,
  "dynamic_full_pool_fallback": true,
  "history_persisted": true,
  "promotion_candidates": true,
  "automatic_promotion": false,
  "periodic_refresh": false,
  "radar_component": "removed",
  "active": true
}
EOF

echo PROVIDERS_ROUTER_V3_READY
echo "state=$STATE"
echo "backup=$BACKUP"
echo "NOTE=Promotion is suggested only; no automatic fixed-slot replacement."
