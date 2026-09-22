#!/usr/bin/env bash
set -euo pipefail

EXEC=/home/ubuntu/Central/runtime/native_executor.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/capability-route-preflight-v1-$STAMP
mkdir -p "$BACKUP"
cp -a "$EXEC" "$BACKUP/native_executor.py"

echo "=== 1. ADD CAPABILITY + ROUTE PREFLIGHT ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/runtime/native_executor.py")
s=p.read_text(encoding="utf-8")

anchor='''def preflight(workspace:Path):
'''
helper='''def route_preflight(instruction:str):
    import importlib.util
    import sys as _sys
    native_path=str(NATIVE)
    if native_path not in _sys.path:
        _sys.path.insert(0,native_path)

    from cli import infer_capability
    from config import load_settings
    from providers import ProviderRegistry
    from router import select

    capability=infer_capability(instruction,"auto")
    cfg=load_settings()
    registry=ProviderRegistry(
        cfg.groq_key,
        cfg.openrouter_key,
        "/home/ubuntu/Central/state/providers.json",
    )
    ranked=select(capability,registry)
    return {
        "capability":capability,
        "routable":bool(ranked),
        "candidates":[
            {"ref":x.get("ref"),"score":x.get("score")}
            for x in (ranked or [])[:8]
        ],
    }

def preflight(workspace:Path):
'''
if 'def route_preflight(instruction:str):' not in s:
    if anchor not in s:
        raise SystemExit("PREFLIGHT_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,helper,1)

needle='''    checks=preflight(workspace)
    failed_checks=[x for x in checks if not x["ok"]]
    if failed_checks:
        reason="PREFLIGHT_FAILED: "+ "; ".join(x["name"]+"="+x["detail"] for x in failed_checks)
        emit_failure(trabajo,workspace,started,reason,checks=checks)
'''
replacement='''    checks=preflight(workspace)
    failed_checks=[x for x in checks if not x["ok"]]
    if failed_checks:
        reason="PREFLIGHT_FAILED: "+ "; ".join(x["name"]+"="+x["detail"] for x in failed_checks)
        emit_failure(trabajo,workspace,started,reason,checks=checks)

    try:
        route_check=route_preflight(instruction)
    except Exception as e:
        emit_failure(
            trabajo,workspace,started,
            "ROUTE_PREFLIGHT_ERROR: "+str(e),
            checks=checks
        )

    if not route_check.get("routable"):
        emit_failure(
            trabajo,workspace,started,
            "NO_VERIFIED_ROUTE_FOR_CAPABILITY: "+str(route_check.get("capability")),
            checks=checks
        )
'''
if 'NO_VERIFIED_ROUTE_FOR_CAPABILITY' not in s:
    if needle not in s:
        raise SystemExit("PREFLIGHT_EXECUTION_ANCHOR_NOT_FOUND")
    s=s.replace(needle,replacement,1)

# Add route_preflight information to final result.
result_anchor='''        "preflight":checks,
        "error":err,
'''
result_new='''        "preflight":checks,
        "route_preflight":route_check,
        "error":err,
'''
if '"route_preflight":route_check' not in s:
    if result_anchor not in s:
        raise SystemExit("RESULT_PREFLIGHT_ANCHOR_NOT_FOUND")
    s=s.replace(result_anchor,result_new,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$EXEC"
echo CAPABILITY_ROUTE_PREFLIGHT_SOURCE_OK

echo "=== 2. STATIC ROUTE PREFLIGHT TESTS ==="
PYTHONPATH=/home/ubuntu/Central/native_v1 python3 - <<'PY'
import importlib.util
spec=importlib.util.spec_from_file_location("ne","/home/ubuntu/Central/runtime/native_executor.py")
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

cases=[
    ("Creá prueba.py que imprima OK.","programacion"),
    ("Respondé solamente con JSON válido.","estructurado"),
    ("Hola, contame qué es Central.","conversacion"),
]
for text,expected in cases:
    r=m.route_preflight(text)
    print(expected,r)
    assert r["capability"]==expected,(text,r)
    assert isinstance(r["candidates"],list),r
    assert r["routable"] is True,r
print("CAPABILITY_ROUTE_PREFLIGHT_STATIC_OK")
PY

echo "=== 3. RESTART CENTRAL JOBS ==="
sudo systemctl restart central-jobs-api.service
for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8091/api/health >/tmp/route-preflight-health.json 2>/dev/null && break
  sleep 1
done
cat /tmp/route-preflight-health.json
echo
systemctl is-active central-jobs-api.service
echo CENTRAL_JOBS_ROUTE_PREFLIGHT_SERVICE_OK

echo "=== 4. LIVE PROGRAMMING JOB ==="
RESP=$(curl -fsS --max-time 10 -H 'Content-Type: application/json'   -d '{"task":"Creá route-preflight-v1.py que imprima exactamente ROUTE_PREFLIGHT_OK, ejecutalo y verificá la salida.","source":"chat","project":"Central","conversation_id":"route-preflight-v1"}'   http://127.0.0.1:8091/api/jobs)
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
assert rp.get("routable") is True,rp
assert rp.get("candidates"),rp
n=r.get("native") or {}
assert n.get("capability")=="programacion",n
print("CAPABILITY_ROUTE_PREFLIGHT_LIVE_OK")
print("selected_model="+str(n.get("model_ref")))
print("candidate_count="+str(len(rp.get("candidates") or [])))
PY

grep -q 'ROUTE_PREFLIGHT_OK' "/home/ubuntu/Central/work/$JOB/route-preflight-v1.py"
echo ROUTE_PREFLIGHT_CANARY_OK

echo CENTRAL_CAPABILITY_ROUTE_PREFLIGHT_V1_READY
echo "backup=$BACKUP"
