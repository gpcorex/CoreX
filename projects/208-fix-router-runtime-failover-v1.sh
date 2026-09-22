#!/usr/bin/env bash
set -euo pipefail

CLI=/home/ubuntu/Central/native_v1/cli.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/router-failover-v1-$STAMP
mkdir -p "$BACKUP"
cp -a "$CLI" "$BACKUP/cli.py"

echo "=== 1. MAKE STRUCTURED MODEL FAILURES TRIGGER FALLBACK ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/cli.py")
s=p.read_text(encoding="utf-8")

old='''            out=Agent(provider,model,ToolBox(root),a.max_steps).run(a.task)
            latency_ms=round((time.monotonic()-started)*1000)
            registry.record_result(ref,True,latency_ms,1.0,capability)
'''
new='''            out=Agent(provider,model,ToolBox(root),a.max_steps).run(a.task)
            if not isinstance(out,dict) or out.get("ok") is not True:
                detail=""
                if isinstance(out,dict):
                    detail=str(out.get("error") or out.get("detail") or out.get("message") or out)[:500]
                else:
                    detail=str(out)[:500]
                raise RuntimeError("MODEL_ATTEMPT_FAILED:"+detail)
            latency_ms=round((time.monotonic()-started)*1000)
            registry.record_result(ref,True,latency_ms,1.0,capability)
'''

if old not in s:
    raise SystemExit("AGENT_RUN_SUCCESS_ANCHOR_NOT_FOUND")

s=s.replace(old,new,1)
p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$CLI"
echo ROUTER_FAILOVER_SOURCE_OK

echo "=== 2. VERIFY FALLBACK LOOP CONTRACT ==="
python3 - <<'PY'
from pathlib import Path
s=Path("/home/ubuntu/Central/native_v1/cli.py").read_text(encoding="utf-8")
assert 'for candidate in ranked:' in s
assert 'MODEL_ATTEMPT_FAILED:' in s
assert 'registry.record_result(ref,False' in s
assert 'attempts.append(' in s
assert 'ALL_ROUTER_CANDIDATES_FAILED:' in s
print("ROUTER_FAILOVER_LOOP_CONTRACT_OK")
PY

echo "=== 3. UNIT TEST: FIRST MODEL RETURNS RATE-LIMIT FAILURE, SECOND SUCCEEDS ==="
PYTHONPATH=/home/ubuntu/Central/native_v1 python3 - <<'PY'
import json,sys,tempfile
from unittest.mock import patch
import cli

class FakeRegistry:
    def __init__(self,*a,**k): self.state={}
    def record_result(self,*a,**k): pass

class FailAgent:
    calls=0
    def __init__(self,*a,**k): pass
    def run(self,task):
        type(self).calls+=1
        if type(self).calls==1:
            return {"ok":False,"error":"groq:HTTP_429:Rate limit reached"}
        return {"ok":True,"answer":"FALLBACK_OK","steps":1}

class DummySettings:
    groq_key="x"
    openrouter_key="y"

ranked=[
    {"ref":"groq/qwen/qwen3.8-27b","score":0.9},
    {"ref":"openrouter/fallback:free","score":0.8},
]

def fake_provider(ref,settings):
    provider,model=ref.split("/",1)
    return provider,model,object()

with tempfile.TemporaryDirectory() as td,      patch.object(cli,"load_settings",return_value=DummySettings()),      patch.object(cli,"ProviderRegistry",FakeRegistry),      patch.object(cli,"select",return_value=ranked),      patch.object(cli,"provider_for_ref",side_effect=fake_provider),      patch.object(cli,"Agent",FailAgent),      patch.object(cli,"ToolBox",lambda root: object()),      patch.object(sys,"argv",["cli.py","Creá prueba.py","--role","auto","--workspace",td]):
    from io import StringIO
    old=sys.stdout
    buf=StringIO(); sys.stdout=buf
    try:
        cli.main()
    finally:
        sys.stdout=old
    out=json.loads(buf.getvalue().strip().splitlines()[-1])
    assert out["ok"] is True,out
    assert out["model_ref"]=="openrouter/fallback:free",out
    assert len(out["attempts"])==2,out
    assert out["attempts"][0]["ok"] is False,out
    assert "429" in out["attempts"][0]["error"],out
    assert out["attempts"][1]["ok"] is True,out
    print("RATE_LIMIT_FALLBACK_UNIT_OK")
    print("first="+out["attempts"][0]["ref"])
    print("second="+out["attempts"][1]["ref"])
PY

echo "=== 4. LIVE NORMAL PROGRAMMING REGRESSION ==="
RESP=$(curl -fsS --max-time 10 -H 'Content-Type: application/json'   -d '{"task":"Creá failover-regression.txt con el texto FAILOVER_REGRESSION_OK, leelo y verificá que coincida exactamente.","source":"chat","project":"Central","conversation_id":"failover-regression"}'   http://127.0.0.1:8091/api/jobs)
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
n=(j.get("result") or {}).get("native") or {}
assert n.get("status")=="ok",n
assert n.get("attempts"),n
print("ROUTER_FAILOVER_LIVE_REGRESSION_OK")
print("model_ref="+str(n.get("model_ref")))
print("attempts="+str(len(n.get("attempts") or [])))
PY

grep -qx 'FAILOVER_REGRESSION_OK' "/home/ubuntu/Central/work/$JOB/failover-regression.txt"
echo ROUTER_FAILOVER_FILE_OK

echo CENTRAL_ROUTER_FAILOVER_V1_READY
echo "backup=$BACKUP"
