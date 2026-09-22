#!/usr/bin/env bash
set -euo pipefail

RUNTIME=/home/ubuntu/Central/runtime
EXEC="$RUNTIME/executor.js"
LEGACY="$RUNTIME/executor.openclaw.js"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-full-default-$STAMP

mkdir -p "$BACKUP"
cp -a "$EXEC" "$BACKUP/executor.js"
test -f "$LEGACY" || { echo "LEGACY_EXECUTOR_MISSING"; exit 1; }

echo "=== 1. PROMOTE CENTRAL NATIVE TO DEFAULT FULL EXECUTOR ==="
cat >"$EXEC" <<'JS'
#!/usr/bin/env node
const fs=require("fs");
const {spawnSync}=require("child_process");

const taskPath=process.argv[2];
if(!taskPath){
  console.error("missing task.json");
  process.exit(2);
}

let task={};
try{
  task=JSON.parse(fs.readFileSync(taskPath,"utf8"));
}catch(e){
  console.error("invalid task json: "+e.message);
  process.exit(2);
}

let source=String(task.source || (task.contexto&&task.contexto.source) || "");
const trabajo=String(task.trabajo || task.job_id || "");

if(trabajo){
  try{
    const jobPath="/home/ubuntu/Central/data/api-jobs/"+trabajo+"/job.json";
    const job=JSON.parse(fs.readFileSync(jobPath,"utf8"));
    if(job && job.source) source=String(job.source);
  }catch(e){}
}

function run(cmd,args,timeout){
  return spawnSync(cmd,args,{
    encoding:"utf8",
    stdio:["ignore","pipe","pipe"],
    timeout
  });
}

function emit(r){
  if(r.stdout) process.stdout.write(r.stdout);
  if(r.stderr) process.stderr.write(r.stderr);
  if(r.error){
    console.error(String(r.error));
    return 1;
  }
  return typeof r.status==="number" ? r.status : 1;
}

// Explicit escape hatch while OpenClaw remains installed as temporary fallback.
if(source==="openclaw-canary" || source==="openclaw-force"){
  process.exit(emit(run(
    "/usr/bin/node",
    ["/home/ubuntu/Central/runtime/executor.openclaw.js",taskPath],
    300000
  )));
}

// Default FULL path: Central Native.
const native=run(
  "/usr/bin/python3",
  ["/home/ubuntu/Central/runtime/native_executor.py",taskPath],
  300000
);

if(!native.error && native.status===0){
  process.exit(emit(native));
}

// Native failed: keep its diagnostics off stdout so Jobs API can still parse
// the legacy executor JSON. OpenClaw is only a temporary safety fallback.
if(native.stderr) process.stderr.write("[native-failed]\n"+native.stderr+"\n");
if(native.stdout) process.stderr.write("[native-stdout]\n"+native.stdout+"\n");

const legacy=run(
  "/usr/bin/node",
  ["/home/ubuntu/Central/runtime/executor.openclaw.js",taskPath],
  300000
);
process.exit(emit(legacy));
JS

chmod 755 "$EXEC"
node --check "$EXEC"
echo NATIVE_FULL_DEFAULT_ROUTER_OK

echo "=== 2. CENTRAL JOBS HEALTH ==="
systemctl restart central-jobs-api.service
for i in $(seq 1 20); do
  if curl -fsS --max-time 2 http://127.0.0.1:8091/api/health >/tmp/native-full-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/native-full-health.json
echo

run_full_test() {
  local label="$1"
  local task="$2"
  echo "=== FULL TEST $label ==="
  local resp job out status
  resp=$(python3 - "$task" "$label" <<'PY'
import json,sys,urllib.request
task,label=sys.argv[1],sys.argv[2]
payload={
  "task":task,
  "source":"chat",
  "project":"Central",
  "conversation_id":"native-full-"+label
}
req=urllib.request.Request(
  "http://127.0.0.1:8091/api/jobs",
  data=json.dumps(payload,ensure_ascii=False).encode(),
  headers={"Content-Type":"application/json"},
  method="POST"
)
with urllib.request.urlopen(req,timeout=10) as r:
    print(r.read().decode())
PY
)
  echo "$resp"
  job=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$resp")
  for i in $(seq 1 180); do
    out=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$job")
    status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$out")
    printf '\rstatus=%s elapsed=%ss' "$status" "$i"
    case "$status" in COMPLETADA|ERROR) break;; esac
    sleep 1
  done
  echo
  echo "$out"
  OUT_JSON="$out" LABEL="$label" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
assert j.get("mode")!="DIRECT",j
r=j.get("result") or {}
assert r.get("jugador")=="Central Native",r
assert r.get("native",{}).get("status")=="ok",r
assert "openclaw" not in r,r
assert "CENTRAL_STATUS=COMPLETADO" in r.get("resultado",""),r
print("FULL_NATIVE_"+os.environ["LABEL"]+"_OK")
PY
  echo "$job"
}

J1=$(run_full_test 1 'Creá un programa Python llamado prueba1.py que imprima exactamente FULL_NATIVE_1_OK. Ejecutalo y verificá que la salida sea exactamente FULL_NATIVE_1_OK.')
ID1=$(echo "$J1" | tail -1)
grep -q 'print' "/home/ubuntu/Central/work/$ID1/prueba1.py"

J2=$(run_full_test 2 'Creá data.json con {"estado":"FULL_NATIVE_2_OK"} y un programa prueba2.py que lea data.json, imprima sólo el valor de estado, ejecutalo y verificá que la salida sea exactamente FULL_NATIVE_2_OK.')
ID2=$(echo "$J2" | tail -1)
grep -q 'FULL_NATIVE_2_OK' "/home/ubuntu/Central/work/$ID2/data.json"

J3=$(run_full_test 3 'Creá nota.txt con el texto BORRADOR, después editalo para que su contenido final sea exactamente FULL_NATIVE_3_OK, leelo y verificá el resultado.')
ID3=$(echo "$J3" | tail -1)
grep -qx 'FULL_NATIVE_3_OK' "/home/ubuntu/Central/work/$ID3/nota.txt"

echo "=== 3. DIRECT REGRESSION ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá /tmp/native-full-direct-regression.txt con el texto DIRECT_STILL_OK y verificá","source":"chat","project":"Central","conversation_id":"native-full-direct-regression"}' \
  http://127.0.0.1:8091/api/jobs)
JOB=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP")
for i in $(seq 1 30); do
  OUT=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB")
  S=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
  case "$S" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
OUT_JSON="$OUT" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
assert j.get("mode")=="DIRECT",j
print("DIRECT_REGRESSION_OK")
PY

echo CENTRAL_NATIVE_FULL_DEFAULT_READY
echo "fallback=openclaw-temporary"
echo "force_legacy_source=openclaw-force"
echo "backup=$BACKUP"
