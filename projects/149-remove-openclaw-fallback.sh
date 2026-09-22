#!/usr/bin/env bash
set -euo pipefail

RUNTIME=/home/ubuntu/Central/runtime
EXEC="$RUNTIME/executor.js"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/remove-openclaw-fallback-$STAMP

mkdir -p "$BACKUP"
cp -a "$EXEC" "$BACKUP/executor.js"

echo "=== 1. REMOVE OPENCLAW FALLBACK ==="
cat >"$EXEC" <<'JS'
#!/usr/bin/env node
const {spawnSync}=require("child_process");

const taskPath=process.argv[2];
if(!taskPath){
  console.error("missing task.json");
  process.exit(2);
}

const r=spawnSync(
  "/usr/bin/python3",
  ["/home/ubuntu/Central/runtime/native_executor.py",taskPath],
  {
    encoding:"utf8",
    stdio:["ignore","pipe","pipe"],
    timeout:300000
  }
);

if(r.stdout) process.stdout.write(r.stdout);
if(r.stderr) process.stderr.write(r.stderr);
if(r.error){
  console.error(String(r.error));
  process.exit(1);
}
process.exit(typeof r.status==="number" ? r.status : 1);
JS

chmod 755 "$EXEC"
node --check "$EXEC"
echo OPENCLAW_FALLBACK_REMOVED

echo "=== 2. RESTART CENTRAL JOBS ==="
systemctl restart central-jobs-api.service
for i in $(seq 1 20); do
  if curl -fsS --max-time 2 http://127.0.0.1:8091/api/health >/tmp/remove-fallback-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/remove-fallback-health.json
echo

echo "=== 3. FULL NATIVE SMOKE ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá final-native.txt con el texto OPENCLAW_FALLBACK_REMOVED_OK, leelo y verificá que coincida exactamente.","source":"chat","project":"Central","conversation_id":"remove-openclaw-fallback"}' \
  http://127.0.0.1:8091/api/jobs)
echo "$RESP"
JOB=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP")

for i in $(seq 1 180); do
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
assert r.get("native",{}).get("status")=="ok",r
assert "openclaw" not in r,r
assert "CENTRAL_STATUS=COMPLETADO" in r.get("resultado",""),r
print("FULL_NATIVE_NO_FALLBACK_OK")
PY

FILE="/home/ubuntu/Central/work/$JOB/final-native.txt"
test -f "$FILE"
grep -qx 'OPENCLAW_FALLBACK_REMOVED_OK' "$FILE"
echo NATIVE_FILE_VERIFY_OK

echo "=== 4. DIRECT REGRESSION ==="
RESP2=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá /tmp/direct-after-openclaw.txt con el texto DIRECT_AFTER_OPENCLAW_OK y verificá","source":"chat","project":"Central","conversation_id":"direct-after-openclaw"}' \
  http://127.0.0.1:8091/api/jobs)
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

echo "=== 5. OPENCLAW SERVICE STATUS ==="
systemctl --user is-active openclaw-gateway.service 2>/dev/null || true
echo "OPENCLAW_SERVICE_LEFT_INTACT_FOR_ROLLBACK"

echo CENTRAL_NATIVE_ONLY_EXECUTION_READY
echo "backup=$BACKUP"
echo "NOTE=OpenClaw fallback removed from execution path; service/files remain intact for rollback."
