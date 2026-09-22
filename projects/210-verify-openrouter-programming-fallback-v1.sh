#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STATE=/home/ubuntu/Central/state/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/openrouter-programming-fallback-v1-$STAMP
mkdir -p "$BACKUP"
cp -a "$STATE" "$BACKUP/providers.json" 2>/dev/null || true

echo "=== 1. REFRESH OPENROUTER DISCOVERY ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
out=r.discover("openrouter")
x=out["openrouter"]
assert x["ok"] and x["count"]>0,x
print("OPENROUTER_DISCOVERY_OK count="+str(x["count"]))
PY

echo "=== 2. FUNCTIONALLY VERIFY FREE OPENROUTER TOOL MODELS ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
import json,time
from config import load_settings
from providers import ProviderRegistry, openrouter_provider

STATE="/home/ubuntu/Central/state/providers.json"
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,STATE)
p=openrouter_provider(s.openrouter_key,40)

refs=[]
for ref in r.all_discovered_refs():
    provider,model=ref.split("/",1)
    if provider!="openrouter":
        continue
    if not (model.endswith(":free") or model=="free"):
        continue
    meta=r.infer_metadata_capabilities(ref)
    if "tools" not in meta:
        continue
    refs.append(ref)

def priority(ref):
    low=ref.lower()
    score=0
    for term,w in (
        ("coder",80),("qwen",70),("gpt",65),("deepseek",60),
        ("llama",50),("nemotron",45),("mistral",40),("gemma",30)
    ):
        if term in low: score+=w
    return (-score,ref)

refs=sorted(refs,key=priority)
print("metadata_tool_candidates="+str(len(refs)))

tool=[{
  "type":"function",
  "function":{
    "name":"cap_test",
    "description":"Capability verification function",
    "parameters":{
      "type":"object",
      "properties":{"value":{"type":"string"}},
      "required":["value"]
    }
  }
}]

passes=[]
attempts=[]
for ref in refs[:15]:
    _,model=ref.split("/",1)
    started=time.monotonic()
    ok=False; detail=""
    try:
        out=p.chat(
            model,
            [{"role":"user","content":"Call cap_test with value exactly OPENROUTER_TOOLS_OK. Do not answer normally."}],
            tools=tool,
            max_tokens=80,
            temperature=0
        )
        msg=((out.get("choices") or [{}])[0].get("message") or {})
        calls=msg.get("tool_calls") or []
        if calls:
            fn=(calls[0].get("function") or {})
            try:
                args=json.loads(fn.get("arguments") or "{}")
            except Exception:
                args={}
            ok=(args.get("value")=="OPENROUTER_TOOLS_OK")
            detail="tool_call="+repr(args)
        else:
            detail="no_tool_call"
    except Exception as e:
        detail=str(e)[:350]

    latency=round((time.monotonic()-started)*1000)
    attempts.append({"ref":ref,"ok":ok,"latency_ms":latency,"detail":detail})
    print(ref,"PASS" if ok else "FAIL","latency_ms="+str(latency),detail[:180])

    r.record_result(ref,ok,latency,1.0 if ok else 0.0,"programacion")
    if ok:
        caps=r.verified_capabilities(ref)
        caps.add("tools")
        r.set_verified_capabilities(ref,sorted(caps))
        passes.append(ref)
        if len(passes)>=2:
            break

report={
  "checked_at":int(time.time()),
  "attempts":attempts,
  "verified_openrouter_programming":passes,
}
with open("/home/ubuntu/Central/state/openrouter-programming-verification.json","w",encoding="utf-8") as f:
    json.dump(report,f,ensure_ascii=False,indent=2); f.write("\n")

if not passes:
    raise SystemExit("NO_FREE_OPENROUTER_TOOL_MODEL_VERIFIED")

print("OPENROUTER_PROGRAMMING_VERIFIED_OK count="+str(len(passes)))
for ref in passes:
    print("verified="+ref)
PY

echo "=== 3. VERIFY ROUTER NOW EXPOSES CROSS-PROVIDER FALLBACK ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
from router import select

s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
xs=select("programacion",r)
refs=[x["ref"] for x in xs]
ors=[x for x in refs if x.startswith("openrouter/")]
print("programming_candidates="+str(len(refs)))
for i,ref in enumerate(refs[:12],1):
    print(str(i)+" "+ref)
assert ors,refs
assert any("tools" in r.verified_capabilities(ref) for ref in ors),ors
print("CROSS_PROVIDER_PROGRAMMING_ROUTE_OK")
print("openrouter_fallback="+ors[0])
PY

echo "=== 4. VERIFY ROUTE PREFLIGHT SEES OPENROUTER ==="
PYTHONPATH=/home/ubuntu/Central/native_v1 python3 - <<'PY'
import importlib.util
spec=importlib.util.spec_from_file_location("ne","/home/ubuntu/Central/runtime/native_executor.py")
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
r=m.route_preflight("Creá app.py que imprima OK, ejecutalo y verificá la salida.")
print(r)
assert r["capability"]=="programacion",r
assert r["routable"] is True,r
assert any(x["ref"].startswith("openrouter/") for x in r["candidates"]),r
print("ROUTE_PREFLIGHT_OPENROUTER_VISIBLE_OK")
PY

echo "=== 5. LIVE NORMAL PROGRAMMING REGRESSION ==="
RESP=$(curl -fsS --max-time 10 -H 'Content-Type: application/json'   -d '{"task":"Creá cross-provider-ready.txt con el texto CROSS_PROVIDER_READY_OK, leelo y verificá que coincida exactamente.","source":"chat","project":"Central","conversation_id":"cross-provider-ready"}'   http://127.0.0.1:8091/api/jobs)
echo "$RESP"
JOB=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' <<<"$RESP")

for i in $(seq 1 120); do
  OUT=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB")
  STATUS=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
  printf '\rstatus=%s elapsed=%ss' "$STATUS" "$i"
  case "$STATUS" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
echo
echo "$OUT"

OUT_JSON="$OUT" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
r=j.get("result") or {}
rp=r.get("route_preflight") or {}
assert rp.get("capability")=="programacion",rp
assert any(x.get("ref","").startswith("openrouter/") for x in rp.get("candidates") or []),rp
n=r.get("native") or {}
assert n.get("status")=="ok",n
print("CROSS_PROVIDER_LIVE_REGRESSION_OK")
print("selected="+str(n.get("model_ref")))
print("preflight_candidates="+str([x.get("ref") for x in rp.get("candidates") or []]))
PY

grep -qx 'CROSS_PROVIDER_READY_OK' "/home/ubuntu/Central/work/$JOB/cross-provider-ready.txt"
echo CROSS_PROVIDER_FILE_OK

echo CENTRAL_OPENROUTER_PROGRAMMING_FALLBACK_V1_READY
echo "verification=/home/ubuntu/Central/state/openrouter-programming-verification.json"
echo "backup=$BACKUP"
