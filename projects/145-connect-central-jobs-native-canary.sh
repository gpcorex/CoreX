#!/usr/bin/env bash
set -euo pipefail

RUNTIME=/home/ubuntu/Central/runtime
NATIVE=/home/ubuntu/Central/native_v1
EXEC="$RUNTIME/executor.js"
LEGACY="$RUNTIME/executor.openclaw.js"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-bridge-$STAMP

mkdir -p "$BACKUP"
cp -a "$EXEC" "$BACKUP/executor.js"
cp -a "$RUNTIME/jobs_api.py" "$BACKUP/jobs_api.py"

echo "=== 1. VERIFY NATIVE STACK ==="
test -f "$NATIVE/cli.py"
test -f "$NATIVE/BUILD_REPORT.json"
python3 - "$NATIVE/BUILD_REPORT.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8"))
assert x.get("ok") is True, x
assert x.get("agent_real")=="passed", x
print("NATIVE_STACK_OK")
PY

echo "=== 2. INSTALL NATIVE EXECUTOR ==="
cat >"$RUNTIME/native_executor.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import json, os, subprocess, sys, time, uuid
from pathlib import Path

NATIVE=Path("/home/ubuntu/Central/native_v1")

def main():
    if len(sys.argv)!=2:
        raise SystemExit("usage: native_executor.py task.json")
    task_path=Path(sys.argv[1]).resolve()
    task=json.loads(task_path.read_text(encoding="utf-8"))
    trabajo=str(task.get("trabajo") or task.get("job_id") or task_path.parent.name)
    instruction=str(task.get("task") or task.get("orden") or task.get("pedido") or "").strip()
    if not instruction:
        raise SystemExit("EMPTY_TASK")
    workspace=Path("/home/ubuntu/Central/work")/trabajo
    workspace.mkdir(parents=True,exist_ok=True)

    started=time.time()
    cmd=[
        sys.executable,str(NATIVE/"cli.py"),
        instruction,
        "--role","tecnico",
        "--workspace",str(workspace),
        "--max-steps","12",
    ]
    cp=subprocess.run(
        cmd,
        env={**os.environ,"PYTHONPATH":str(NATIVE)},
        text=True,capture_output=True,timeout=240
    )
    ended=time.time()
    stdout=cp.stdout.strip()
    stderr=cp.stderr.strip()

    result_obj=None
    if stdout:
        try: result_obj=json.loads(stdout.splitlines()[-1])
        except Exception: pass

    ok=(cp.returncode==0 and isinstance(result_obj,dict) and result_obj.get("ok") is True)
    answer=(result_obj or {}).get("answer") if result_obj else None
    if ok:
        resultado=(answer or "Tarea completada.")+"\nCENTRAL_STATUS=COMPLETADO"
        estado="Completado"
        err=None
    else:
        resultado=stdout or stderr or "Native executor failed"
        estado="Requiere intervención"
        err=stderr or (None if cp.returncode==0 else f"returncode={cp.returncode}")

    out={
        "central_run_id":str(uuid.uuid4()),
        "task_id":"TASK-NATIVE-"+uuid.uuid4().hex[:8],
        "trabajo":trabajo,
        "jugador":"Central Native",
        "workspace":str(workspace),
        "estado":estado,
        "inicio":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(started)),
        "fin":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(ended)),
        "duracion_ms":int((ended-started)*1000),
        "resultado":resultado,
        "native":{
            "status":"ok" if ok else "error",
            "provider":(result_obj or {}).get("provider"),
            "model":(result_obj or {}).get("model"),
            "steps":(result_obj or {}).get("steps"),
        },
        "error":err,
    }
    print(json.dumps(out,ensure_ascii=False))
    raise SystemExit(0 if ok else 1)

if __name__=="__main__":
    main()
PY
chmod 755 "$RUNTIME/native_executor.py"
python3 -m py_compile "$RUNTIME/native_executor.py"
echo NATIVE_EXECUTOR_OK

echo "=== 3. WRAP CURRENT EXECUTOR WITH CANARY ROUTING ==="
if [ ! -f "$LEGACY" ]; then
  cp -a "$EXEC" "$LEGACY"
fi

cat >"$EXEC" <<'JS'
#!/usr/bin/env node
const fs=require("fs");
const {spawnSync}=require("child_process");
const path=require("path");

const taskPath=process.argv[2];
if(!taskPath){
  console.error("missing task.json");
  process.exit(2);
}
let task={};
try{ task=JSON.parse(fs.readFileSync(taskPath,"utf8")); }
catch(e){ console.error("invalid task json: "+e.message); process.exit(2); }

const source=String(task.source || (task.contexto&&task.contexto.source) || "");
const useNative=(source==="native-smoke" || source==="native-canary");

const cmd=useNative ? "/usr/bin/python3" : "/usr/bin/node";
const args=useNative
  ? ["/home/ubuntu/Central/runtime/native_executor.py",taskPath]
  : ["/home/ubuntu/Central/runtime/executor.openclaw.js",taskPath];

const r=spawnSync(cmd,args,{encoding:"utf8",stdio:["ignore","pipe","pipe"],timeout:300000});
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
echo EXECUTOR_CANARY_ROUTER_OK

echo "=== 4. RESTART JOBS API ==="
systemctl restart central-jobs-api.service
for i in $(seq 1 20); do
  if curl -fsS --max-time 2 http://127.0.0.1:8091/api/health >/tmp/native-bridge-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/native-bridge-health.json
echo

echo "=== 5. VERIFY LEGACY DIRECT PATH STILL WORKS ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá /tmp/native-bridge-direct.txt con el texto DIRECT_STILL_OK y verificá","source":"chat","project":"Central","conversation_id":"native-bridge-direct"}' \
  http://127.0.0.1:8091/api/jobs)
echo "$RESP"
JOB=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP")
for i in $(seq 1 30); do
  OUT=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB")
  S=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
  case "$S" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
echo "$OUT"
OUT_JSON="$OUT" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
assert j.get("mode")=="DIRECT",j
print("DIRECT_REGRESSION_OK")
PY

echo "=== 6. NATIVE CANARY THROUGH CENTRAL JOBS ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá native-canary.txt con el texto CENTRAL_NATIVE_CANARY_OK, leelo y verificá que coincida exactamente.","source":"native-smoke","project":"Central","conversation_id":"native-canary"}' \
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
assert "CENTRAL_STATUS=COMPLETADO" in r.get("resultado",""),r
print("CENTRAL_JOBS_NATIVE_CANARY_OK")
PY

WORK="/home/ubuntu/Central/work/$JOB/native-canary.txt"
test -f "$WORK"
grep -qx 'CENTRAL_NATIVE_CANARY_OK' "$WORK"
echo NATIVE_CANARY_FILE_OK

echo "CENTRAL_NATIVE_BRIDGE_READY"
echo "mode=canary-only"
echo "legacy_executor=$LEGACY"
echo "backup=$BACKUP"
echo "NOTE=Normal FULL jobs still use OpenClaw; only source native-smoke/native-canary uses Central Native."
