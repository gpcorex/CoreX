#!/usr/bin/env bash
set -euo pipefail

RUNTIME=/home/ubuntu/Central/runtime
NATIVE=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/routing-evidence-v6-$STAMP

mkdir -p "$BACKUP"
cp -a "$RUNTIME/native_executor.py" "$BACKUP/native_executor.py"
[ -f "$NATIVE/BUILD_REPORT.json" ] && cp -a "$NATIVE/BUILD_REPORT.json" "$BACKUP/BUILD_REPORT.json"

echo "=== 1. EXPOSE ROUTER EVIDENCE IN CENTRAL JOB RESULT ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/runtime/native_executor.py")
s=p.read_text(encoding="utf-8")
old='''        "native":{
            "status":"ok" if ok else "error",
            "provider":(result_obj or {}).get("provider"),
            "model":(result_obj or {}).get("model"),
            "steps":(result_obj or {}).get("steps"),
        },
'''
new='''        "native":{
            "status":"ok" if ok else "error",
            "provider":(result_obj or {}).get("provider"),
            "model":(result_obj or {}).get("model"),
            "model_ref":(result_obj or {}).get("model_ref"),
            "capability":(result_obj or {}).get("capability"),
            "router_score":(result_obj or {}).get("router_score"),
            "steps":(result_obj or {}).get("steps"),
            "attempts":(result_obj or {}).get("attempts") or [],
        },
'''
if old not in s:
    raise SystemExit("NATIVE_RESULT_ANCHOR_NOT_FOUND")
p.write_text(s.replace(old,new,1),encoding="utf-8")
PY
python3 -m py_compile "$RUNTIME/native_executor.py"
echo ROUTING_EVIDENCE_EXPOSED_OK

echo "=== 2. VERIFY CAPABILITY STATUS SNAPSHOT ==="
sudo -u ubuntu PYTHONPATH="$NATIVE" python3 "$NATIVE/capability_status.py" > /home/ubuntu/Central/state/capability-status.json
python3 - <<'PY'
import json
p="/home/ubuntu/Central/state/capability-status.json"
x=json.load(open(p,encoding="utf-8"))
assert x["programacion"]["count"]>=1,x
assert x["contexto_medio"]["count"]>=1,x
assert x["contexto_largo"]["count"]==0,x
assert x["voz"]["count"]==0,x
print("CAPABILITY_SNAPSHOT_OK")
print("programacion=",x["programacion"]["count"])
print("contexto_medio=",x["contexto_medio"]["count"])
print("contexto_largo=",x["contexto_largo"]["count"])
print("vision=",x["vision"]["count"])
print("voz=",x["voz"]["count"])
PY

echo "=== 3. LIVE ROUTER-EVIDENCE TEST ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json'   -d '{"task":"Creá routing-evidence.py que imprima exactamente ROUTING_EVIDENCE_OK, ejecutalo y verificá la salida.","source":"chat","project":"Central","conversation_id":"routing-evidence-v6"}'   http://127.0.0.1:8091/api/jobs)
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
n=(j.get("result") or {}).get("native") or {}
assert n.get("status")=="ok",n
assert n.get("capability")=="programacion",n
assert n.get("model_ref"),n
assert isinstance(n.get("attempts"),list) and n["attempts"],n
assert n["attempts"][-1].get("ok") is True,n
print("ROUTER_EVIDENCE_LIVE_OK")
print("capability="+str(n.get("capability")))
print("model_ref="+str(n.get("model_ref")))
print("router_score="+str(n.get("router_score")))
print("attempts="+str(len(n.get("attempts") or [])))
PY

grep -q 'ROUTING_EVIDENCE_OK' "/home/ubuntu/Central/work/$JOB/routing-evidence.py"

echo "=== 4. DIRECT REGRESSION ==="
RESP2=$(curl -fsS --max-time 5 -H 'Content-Type: application/json'   -d '{"task":"Creá /tmp/routing-evidence-direct.txt con el texto ROUTING_DIRECT_OK y verificá","source":"chat","project":"Central","conversation_id":"routing-evidence-direct"}'   http://127.0.0.1:8091/api/jobs)
JOB2=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP2")
for i in $(seq 1 30); do
  OUT2=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB2")
  S2=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT2")
  case "$S2" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
OUT2_JSON="$OUT2" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT2_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
assert j.get("mode")=="DIRECT",j
print("DIRECT_REGRESSION_OK")
PY

cat >"$NATIVE/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "routing-evidence-v6",
  "router_evidence_in_job_result": true,
  "capability_status_snapshot": true,
  "periodic_refresh": false,
  "active": true
}
EOF

echo CENTRAL_ROUTING_EVIDENCE_V6_READY
echo "backup=$BACKUP"
