#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=/home/ubuntu/Central/state
STATE_FILE=$STATE_DIR/providers.json
DEST=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/providers-state-permissions-$STAMP

mkdir -p "$BACKUP"
[ -f "$STATE_FILE" ] && cp -a "$STATE_FILE" "$BACKUP/providers.json"

echo "=== 1. FIX STATE DIRECTORY OWNERSHIP ==="
mkdir -p "$STATE_DIR"
chown -R ubuntu:ubuntu "$STATE_DIR"
chmod 775 "$STATE_DIR"
[ -f "$STATE_FILE" ] && chmod 664 "$STATE_FILE"
rm -f "$STATE_DIR/providers.tmp"
echo PROVIDERS_STATE_PERMISSIONS_OK

echo "=== 2. VERIFY WRITE AS UBUNTU ==="
sudo -u ubuntu python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/state/providers.tmp")
p.write_text("WRITE_OK\n",encoding="utf-8")
assert p.read_text(encoding="utf-8")=="WRITE_OK\n"
p.unlink()
print("PROVIDERS_STATE_WRITE_OK")
PY

echo "=== 3. ROUTER V2 LIVE RETEST ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá router-v2-live-2.py que imprima exactamente ROUTER_V2_LIVE_2_OK, ejecutalo y verificá la salida.","source":"chat","project":"Central","conversation_id":"router-v2-live-2"}' \
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
assert "openclaw" not in r,r
n=r.get("native") or {}
assert n.get("status")=="ok",r
print("CENTRAL_JOBS_ROUTER_V2_OK")
PY

grep -q 'ROUTER_V2_LIVE_2_OK' "/home/ubuntu/Central/work/$JOB/router-v2-live-2.py"

echo "=== 4. VERIFY METRICS PERSISTED ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
import json
p="/home/ubuntu/Central/state/providers.json"
x=json.load(open(p,encoding="utf-8"))
metrics=x.get("metrics",{})
assert metrics, x
print("PROVIDER_METRICS_OK")
for ref,m in metrics.items():
    print(ref,"success="+str(m.get("success",0)),"fail="+str(m.get("fail",0)),"last_ok="+str(m.get("last_ok")))
PY

echo ROUTER_V2_STATE_PERMISSION_FIXED
echo "backup=$BACKUP"
