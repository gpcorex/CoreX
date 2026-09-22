#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STATE=/home/ubuntu/Central/state
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/router-audit-v7-$STAMP

mkdir -p "$BACKUP"
[ -f "$DEST/BUILD_REPORT.json" ] && cp -a "$DEST/BUILD_REPORT.json" "$BACKUP/BUILD_REPORT.json"

echo "=== 1. INSTALL ROUTER/PROVIDERS AUDIT SNAPSHOT ==="
cat >"$DEST/router_status.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import json, os, time
from config import load_settings
from providers import ProviderRegistry
from router import select, requirements_for

STATE="/home/ubuntu/Central/state/providers.json"
VERIFY="/home/ubuntu/Central/state/capability-verification.json"
OUT="/home/ubuntu/Central/state/router-status.json"

CAPS=[
    "programacion",
    "razonamiento",
    "conversacion",
    "estructurado",
    "contexto_medio",
    "contexto_largo",
    "vision",
    "voz",
]

def load_json(path,default):
    try:
        with open(path,encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default

def main():
    settings=load_settings()
    r=ProviderRegistry(settings.groq_key,settings.openrouter_key,STATE)

    discovered={}
    for ref in r.all_discovered_refs():
        provider,_=ref.split("/",1)
        discovered[provider]=discovered.get(provider,0)+1

    capability={}
    warnings=[]
    for cap in CAPS:
        req=requirements_for(cap)
        ranked=select(cap,r)
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
        capability[cap]={
            "requirements":req,
            "routable_count":len(routable),
            "top":routable[0] if routable else None,
            "candidates":rows,
            "fixed":[x.get("ref") for x in r.get_fixed(cap)],
        }
        if not routable:
            warnings.append("NO_ROUTE:"+cap)

    metrics={}
    for ref,m in (r.state.get("metrics") or {}).items():
        success=int(m.get("success",0) or 0)
        fail=int(m.get("fail",0) or 0)
        total=success+fail
        metrics[ref]={
            "success":success,
            "fail":fail,
            "success_rate":round(success/total,3) if total else None,
            "last_ok":m.get("last_ok"),
            "latency_ms_tail":(m.get("latency_ms") or [])[-5:],
            "compliance":m.get("compliance"),
        }

    verification=load_json(VERIFY,{})
    promotions=r.state.get("promotions") or {}

    report={
        "generated_at":int(time.time()),
        "providers":{
            "discovered_total":sum(discovered.values()),
            "by_provider":discovered,
        },
        "capabilities":capability,
        "verified_capabilities":r.state.get("verified_capabilities") or {},
        "metrics":metrics,
        "promotions":promotions,
        "latest_functional_verification":verification,
        "warnings":warnings,
    }

    tmp=OUT+".tmp"
    with open(tmp,"w",encoding="utf-8") as f:
        json.dump(report,f,ensure_ascii=False,indent=2)
        f.write("\n")
    os.replace(tmp,OUT)

    print("ROUTER_STATUS")
    print("discovered_total="+str(report["providers"]["discovered_total"]))
    print("providers="+json.dumps(discovered,sort_keys=True))
    for cap in CAPS:
        c=capability[cap]
        top=(c["top"] or {}).get("ref")
        print(f"{cap}: routable={c['routable_count']} top={top}")
    print("promotion_candidates="+str(sum(len(v) for v in promotions.values() if isinstance(v,list))))
    print("warnings="+(",".join(warnings) if warnings else "none"))
    print("snapshot="+OUT)

if __name__=="__main__":
    main()
PY

chmod 755 "$DEST/router_status.py"
python3 -m py_compile "$DEST/router_status.py"
echo ROUTER_STATUS_TOOL_OK

echo "=== 2. GENERATE LIVE SNAPSHOT ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 "$DEST/router_status.py"

echo "=== 3. VALIDATE SNAPSHOT CONTRACT ==="
python3 - <<'PY'
import json
p="/home/ubuntu/Central/state/router-status.json"
x=json.load(open(p,encoding="utf-8"))
assert x["providers"]["discovered_total"]>=1,x
assert x["capabilities"]["programacion"]["routable_count"]>=1,x
assert x["capabilities"]["conversacion"]["routable_count"]>=1,x
assert x["capabilities"]["vision"]["routable_count"]>=1,x
assert x["capabilities"]["voz"]["routable_count"]==0,x
assert x["capabilities"]["contexto_largo"]["routable_count"]==0,x
assert x["capabilities"]["programacion"]["top"]["ref"],x
print("ROUTER_STATUS_CONTRACT_OK")
PY

echo "=== 4. VERIFY TOP PROGRAMMING ROUTE IS FUNCTIONALLY PROVEN ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
import json
from config import load_settings
from providers import ProviderRegistry
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
x=json.load(open("/home/ubuntu/Central/state/router-status.json",encoding="utf-8"))
ref=x["capabilities"]["programacion"]["top"]["ref"]
caps=r.verified_capabilities(ref)
assert "tools" in caps,(ref,caps)
print("TOP_PROGRAMMING_ROUTE_VERIFIED_OK",ref)
PY

echo "=== 5. LIVE JOB REGRESSION + EVIDENCE MATCH ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json'   -d '{"task":"Creá router-audit-v7.py que imprima exactamente ROUTER_AUDIT_V7_OK, ejecutalo y verificá la salida.","source":"chat","project":"Central","conversation_id":"router-audit-v7"}'   http://127.0.0.1:8091/api/jobs)
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
assert n.get("router_score") is not None,n
assert n.get("attempts"),n
print("ROUTER_AUDIT_LIVE_JOB_OK")
print("capability="+str(n["capability"]))
print("model_ref="+str(n["model_ref"]))
print("router_score="+str(n["router_score"]))
print("attempts="+str(len(n["attempts"])))
PY

grep -qx 'print("ROUTER_AUDIT_V7_OK")' "/home/ubuntu/Central/work/$JOB/router-audit-v7.py" || grep -q 'ROUTER_AUDIT_V7_OK' "/home/ubuntu/Central/work/$JOB/router-audit-v7.py"

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "router-audit-v7",
  "snapshot": "/home/ubuntu/Central/state/router-status.json",
  "provider_discovery_summary": true,
  "capability_routes": true,
  "functional_verification_visible": true,
  "model_metrics_visible": true,
  "promotion_candidates_visible": true,
  "warnings_visible": true,
  "active": true
}
EOF

echo CENTRAL_ROUTER_AUDIT_V7_READY
echo "snapshot=/home/ubuntu/Central/state/router-status.json"
echo "backup=$BACKUP"
