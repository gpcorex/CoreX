#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/verified-routing-v8-$STAMP

mkdir -p "$BACKUP"
cp -a "$DEST/router.py" "$DEST/router_status.py" "$BACKUP/" 2>/dev/null || true
[ -f "$DEST/BUILD_REPORT.json" ] && cp -a "$DEST/BUILD_REPORT.json" "$BACKUP/BUILD_REPORT.json"

echo "=== 1. ENFORCE VERIFIED-ONLY DYNAMIC ROUTING ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/router.py")
s=p.read_text(encoding="utf-8")

old='''        # Critical rule: never infer a capability from a model name.
        # Requirements must be verified explicitly or supported by provider metadata.
        caps=registry.capabilities_for(ref)
        if not req.issubset(caps):
            continue
'''

new='''        # Runtime routing is stricter than discovery:
        # provider metadata may nominate a model for testing, but only a
        # functional PASS can make it routable for a required capability.
        caps=registry.verified_capabilities(ref)
        if not req.issubset(caps):
            continue
'''

if old not in s:
    raise SystemExit("DYNAMIC_CAPABILITY_ANCHOR_NOT_FOUND")
p.write_text(s.replace(old,new,1),encoding="utf-8")
PY
python3 -m py_compile "$DEST/router.py"
echo VERIFIED_ONLY_DYNAMIC_ROUTING_OK

echo "=== 2. FIX AUDIT TO COUNT FULL ROUTE BEFORE DISPLAY TRUNCATION ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/router_status.py")
s=p.read_text(encoding="utf-8")

old='''        ranked=select(cap,r)
        rows=[]
        for item in ranked[:10]:
            verified=sorted(r.verified_capabilities(item["ref"]))
            rows.append({
                "ref":item["ref"],
                "score":item.get("score"),
                "dynamic":bool(item.get("dynamic")),
                "verified_capabilities":verified,
                "requirements_satisfied":set(req).issubset(set(verified)) if req else True,
            })
        routable=[x for x in rows if x["requirements_satisfied"]]
'''

new='''        ranked=select(cap,r)
        full_rows=[]
        for item in ranked:
            verified=sorted(r.verified_capabilities(item["ref"]))
            full_rows.append({
                "ref":item["ref"],
                "score":item.get("score"),
                "dynamic":bool(item.get("dynamic")),
                "verified_capabilities":verified,
                "requirements_satisfied":set(req).issubset(set(verified)) if req else True,
            })
        routable=[x for x in full_rows if x["requirements_satisfied"]]
        rows=full_rows[:10]
'''

if old not in s:
    raise SystemExit("AUDIT_TRUNCATION_ANCHOR_NOT_FOUND")
p.write_text(s.replace(old,new,1),encoding="utf-8")
PY
python3 -m py_compile "$DEST/router_status.py"
echo ROUTER_AUDIT_FULL_COUNT_OK

echo "=== 3. CLEAN LEGACY PROMOTION BUCKET ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
prom=r.state.setdefault("promotions",{})
prom.pop("tecnico",None)
r.save()
print("LEGACY_TECNICO_PROMOTION_REMOVED")
PY

echo "=== 4. STRICT ROUTE TESTS ==="
cat >"$DEST/tests/test_verified_routing_v8.py" <<'PY'
import unittest
from router import select

class FakeRegistry:
    def __init__(self):
        self.state={"metrics":{}}
    def get_fixed(self,cap): return []
    def all_discovered_refs(self):
        return ["openrouter/unverified-vision:free","groq/verified-vision"]
    def verified_capabilities(self,ref):
        return {"vision"} if ref=="groq/verified-vision" else set()

class VerifiedRoutingTests(unittest.TestCase):
    def test_unverified_metadata_candidate_is_not_routable(self):
        refs=[x["ref"] for x in select("vision",FakeRegistry())]
        self.assertEqual(refs,["groq/verified-vision"])

if __name__=="__main__": unittest.main()
PY
PYTHONPATH="$DEST" python3 -m unittest discover -s "$DEST/tests" -p 'test_verified_routing_v8.py' -v
echo VERIFIED_ROUTING_TEST_OK

echo "=== 5. GENERATE CORRECTED LIVE AUDIT ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 "$DEST/router_status.py"

echo "=== 6. ASSERT CURRENT VERIFIED ROUTES ==="
python3 - <<'PY'
import json
p="/home/ubuntu/Central/state/router-status.json"
x=json.load(open(p,encoding="utf-8"))
v=x["capabilities"]["vision"]
assert v["routable_count"]>=1,v
assert v["top"]["ref"]=="groq/qwen/qwen3.8-27b",v
assert x["capabilities"]["voz"]["routable_count"]==0,x["capabilities"]["voz"]
assert x["capabilities"]["contexto_largo"]["routable_count"]==0,x["capabilities"]["contexto_largo"]
assert "NO_ROUTE:vision" not in x["warnings"],x["warnings"]
print("CORRECTED_ROUTE_AUDIT_OK")
print("vision_top="+v["top"]["ref"])
print("vision_routable="+str(v["routable_count"]))
print("warnings="+(",".join(x["warnings"]) if x["warnings"] else "none"))
PY

echo "=== 7. LIVE PROGRAMMING REGRESSION ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json'   -d '{"task":"Creá verified-routing-v8.py que imprima exactamente VERIFIED_ROUTING_V8_OK, ejecutalo y verificá la salida.","source":"chat","project":"Central","conversation_id":"verified-routing-v8"}'   http://127.0.0.1:8091/api/jobs)
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
n=(j.get("result") or {}).get("native") or {}
assert n.get("capability")=="programacion",n
assert n.get("model_ref"),n
print("VERIFIED_ROUTING_LIVE_REGRESSION_OK",n["model_ref"])
PY

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "verified-routing-v8",
  "dynamic_runtime_requires_functional_pass": true,
  "metadata_used_for_test_nomination_only": true,
  "audit_counts_full_ranked_set": true,
  "legacy_tecnico_promotion_removed": true,
  "active": true
}
EOF

echo CENTRAL_VERIFIED_ROUTING_V8_READY
echo "backup=$BACKUP"
