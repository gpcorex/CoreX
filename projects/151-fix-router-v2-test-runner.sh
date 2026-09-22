#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/router-v2-testfix-$STAMP
mkdir -p "$BACKUP"
cp -a "$DEST/tests/test_router_v2.py" "$BACKUP/test_router_v2.py"

echo "=== 1. ROUTER V2 TEST FIX ==="
PYTHONPATH="$DEST" python3 -m unittest discover -s "$DEST/tests" -p 'test_router_v2.py' -v
echo ROUTER_V2_TESTS_OK

echo "=== 2. REAL PROVIDER DISCOVERY ON DEMAND ==="
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

echo "=== 3. REAL HEALTHCHECK OF PROGRAMMING CANDIDATES ==="
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

echo "=== 4. REGRESSION: CENTRAL NATIVE STILL WORKS ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json'   -d '{"task":"Creá providers-router-v2-fix.txt con el texto PROVIDERS_ROUTER_V2_FIX_OK, leelo y verificá que coincida exactamente.","source":"chat","project":"Central","conversation_id":"providers-router-v2-fix"}'   http://127.0.0.1:8091/api/jobs)
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
grep -qx 'PROVIDERS_ROUTER_V2_FIX_OK' "/home/ubuntu/Central/work/$JOB/providers-router-v2-fix.txt"

echo "=== 5. BUILD REPORT ==="
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

echo PROVIDERS_ROUTER_V2_READY
echo "state=/home/ubuntu/Central/state/providers.json"
echo "backup=$BACKUP"
echo "NOTE=No periodic timer installed."
