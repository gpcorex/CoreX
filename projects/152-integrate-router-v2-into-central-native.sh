#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STATE=/home/ubuntu/Central/state/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/router-v2-cli-integration-$STAMP

mkdir -p "$BACKUP"
for f in cli.py router.py providers.py BUILD_REPORT.json; do
  [ -e "$DEST/$f" ] && cp -a "$DEST/$f" "$BACKUP/$f"
done

echo "=== 1. PATCH CLI TO USE PROVIDERS REGISTRY + ROUTER V2 ==="
cat >"$DEST/cli.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, tempfile, time
from config import load_settings
from providers import ProviderRegistry, groq_provider, openrouter_provider
from router import select
from tools import ToolBox
from agent import Agent

def provider_for_ref(ref:str,settings):
    provider,model=ref.split("/",1)
    if provider=="groq":
        return provider,model,groq_provider(settings.groq_key)
    if provider=="openrouter":
        return provider,model,openrouter_provider(settings.openrouter_key)
    raise RuntimeError("UNSUPPORTED_PROVIDER:"+provider)

def infer_capability(task:str,role:str)->str:
    t=(task or "").lower()
    if role and role!="auto":
        return role
    code_words=("python","programa","código","codigo","script","archivo","json","bash","programar","función","funcion","test")
    reasoning_words=("analiz","razon","compar","explic","investig","diagnostic")
    if any(w in t for w in code_words): return "programacion"
    if any(w in t for w in reasoning_words): return "razonamiento"
    return "rapido"

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("task")
    ap.add_argument("--role",default="auto")
    ap.add_argument("--workspace",default=None)
    ap.add_argument("--max-steps",type=int,default=12)
    a=ap.parse_args()

    settings=load_settings()
    registry=ProviderRegistry(
        settings.groq_key,
        settings.openrouter_key,
        "/home/ubuntu/Central/state/providers.json",
    )
    capability=infer_capability(a.task,a.role)
    ranked=select(capability,registry)
    if not ranked:
        raise SystemExit("NO_ROUTER_CANDIDATES:"+capability)

    root=a.workspace or tempfile.mkdtemp(prefix="central-native-")
    attempts=[]
    last_error=None

    for candidate in ranked:
        ref=candidate["ref"]
        provider_name,model,provider=provider_for_ref(ref,settings)
        started=time.monotonic()
        try:
            out=Agent(provider,model,ToolBox(root),a.max_steps).run(a.task)
            latency_ms=round((time.monotonic()-started)*1000)
            registry.record_result(ref,True,latency_ms,1.0)
            out.update({
                "provider":provider_name,
                "model":model,
                "model_ref":ref,
                "workspace":root,
                "capability":capability,
                "router_score":candidate.get("score"),
                "attempts":attempts+[{"ref":ref,"ok":True,"latency_ms":latency_ms}],
            })
            print(json.dumps(out,ensure_ascii=False))
            return
        except Exception as e:
            latency_ms=round((time.monotonic()-started)*1000)
            registry.record_result(ref,False,latency_ms,0.0)
            attempts.append({"ref":ref,"ok":False,"latency_ms":latency_ms,"error":str(e)[:300]})
            last_error=e

    raise SystemExit("ALL_ROUTER_CANDIDATES_FAILED:"+str(last_error))

if __name__=="__main__":
    main()
PY

chmod 755 "$DEST/cli.py"
python3 -m py_compile "$DEST/cli.py"
echo CLI_ROUTER_V2_OK

echo "=== 2. ADD ROUTER INTEGRATION TEST ==="
cat >"$DEST/tests/test_cli_router_v2.py" <<'PY'
import unittest
from cli import infer_capability

class CliRouterV2Tests(unittest.TestCase):
    def test_programming_detection(self):
        self.assertEqual(infer_capability("Creá un programa Python","auto"),"programacion")
    def test_reasoning_detection(self):
        self.assertEqual(infer_capability("Analizá estas opciones","auto"),"razonamiento")
    def test_fast_detection(self):
        self.assertEqual(infer_capability("Hola","auto"),"rapido")
    def test_explicit_role(self):
        self.assertEqual(infer_capability("Hola","programacion"),"programacion")

if __name__=="__main__": unittest.main()
PY

PYTHONPATH="$DEST" python3 -m unittest discover -s "$DEST/tests" -p 'test_cli_router_v2.py' -v
echo CLI_ROUTER_V2_TESTS_OK

echo "=== 3. SHOW CURRENT PROGRAMMING RANKING ==="
PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
from router import select
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
ranked=select("programacion",r)
assert ranked, ranked
for i,c in enumerate(ranked,1):
    print(i,c["ref"],"score="+str(c["score"]))
print("ROUTER_V2_ACTIVE_RANKING_OK")
PY

echo "=== 4. REAL PROGRAMMING TEST THROUGH CENTRAL JOBS ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá router-v2-live.py que imprima exactamente ROUTER_V2_LIVE_OK, ejecutalo y verificá la salida.","source":"chat","project":"Central","conversation_id":"router-v2-live"}' \
  http://127.0.0.1:8091/api/jobs)
echo "$RESP"
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
n=r.get("native") or {}
assert n.get("status")=="ok",r
assert "openclaw" not in r,r
print("CENTRAL_JOBS_ROUTER_V2_OK")
PY

grep -q 'ROUTER_V2_LIVE_OK' "/home/ubuntu/Central/work/$JOB/router-v2-live.py"

echo "=== 5. VERIFY PROVIDER METRICS WERE UPDATED ==="
PYTHONPATH="$DEST" python3 - <<'PY'
import json
p="/home/ubuntu/Central/state/providers.json"
x=json.load(open(p,encoding="utf-8"))
metrics=x.get("metrics",{})
assert metrics, x
print("PROVIDER_METRICS_OK")
for ref,m in metrics.items():
    print(ref,"success="+str(m.get("success",0)),"fail="+str(m.get("fail",0)),"last_ok="+str(m.get("last_ok")))
PY

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "router-v2-cli-integration",
  "radar_component": "removed",
  "provider_discovery": "on-demand",
  "router_dynamic_scoring": true,
  "router_used_by_cli": true,
  "provider_metrics_persisted": true,
  "periodic_refresh": false,
  "tests": "passed",
  "active": true
}
EOF

echo CENTRAL_ROUTER_V2_INTEGRATED
echo "backup=$BACKUP"
echo "state=$STATE"
