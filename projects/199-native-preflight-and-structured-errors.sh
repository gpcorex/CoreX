#!/usr/bin/env bash
set -euo pipefail

EXEC=/home/ubuntu/Central/runtime/native_executor.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-preflight-v1-$STAMP
mkdir -p "$BACKUP"
cp -a "$EXEC" "$BACKUP/native_executor.py"

echo "=== 1. INSTALL PREFLIGHT + STRUCTURED FAILURE REPORTING ==="
python3 - <<'PY'
from pathlib import Path
import re

p=Path("/home/ubuntu/Central/runtime/native_executor.py")
s=p.read_text(encoding="utf-8")

# Add helper functions before main.
anchor='''def main():
'''
helpers='''def preflight(workspace:Path):
    checks=[]
    def add(name,ok,detail=""):
        checks.append({"name":name,"ok":bool(ok),"detail":str(detail)})
    required=[
        NATIVE/"cli.py",
        NATIVE/"router.py",
        NATIVE/"providers.py",
        NATIVE/"tools.py",
    ]
    for f in required:
        add("file:"+f.name,f.is_file(),str(f))
    try:
        workspace.mkdir(parents=True,exist_ok=True)
        probe=workspace/".preflight-write"
        probe.write_text("ok",encoding="utf-8")
        probe.unlink(missing_ok=True)
        add("workspace_writable",True,str(workspace))
    except Exception as e:
        add("workspace_writable",False,e)
    try:
        st=os.statvfs(str(workspace))
        free=st.f_bavail*st.f_frsize
        add("disk_free_mb",free>=256,round(free/1024/1024))
    except Exception as e:
        add("disk_free_mb",False,e)
    try:
        import py_compile
        py_compile.compile(str(NATIVE/"cli.py"),doraise=True)
        add("cli_compiles",True)
    except Exception as e:
        add("cli_compiles",False,e)
    return checks

def emit_failure(trabajo,workspace,started,reason,checks=None,stdout="",stderr="",result_obj=None,attachments=None):
    ended=time.time()
    native={
        "status":"error",
        "provider":(result_obj or {}).get("provider"),
        "model":(result_obj or {}).get("model"),
        "model_ref":(result_obj or {}).get("model_ref"),
        "capability":(result_obj or {}).get("capability"),
        "router_score":(result_obj or {}).get("router_score"),
        "attempts":(result_obj or {}).get("attempts"),
        "steps":(result_obj or {}).get("steps"),
        "error":(result_obj or {}).get("error"),
    }
    out={
        "central_run_id":str(uuid.uuid4()),
        "task_id":"TASK-NATIVE-"+uuid.uuid4().hex[:8],
        "trabajo":trabajo,
        "jugador":"Central Native",
        "workspace":str(workspace),
        "estado":"Requiere intervención",
        "inicio":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(started)),
        "fin":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(ended)),
        "duracion_ms":int((ended-started)*1000),
        "resultado":stdout or stderr or reason,
        "native":native,
        "preflight":checks or [],
        "attachments":attachments or [],
        "error":reason,
        "stderr":stderr[-2000:] if stderr else "",
    }
    print(json.dumps(out,ensure_ascii=False))
    raise SystemExit(1)

'''

if 'def preflight(workspace:Path):' not in s:
    if anchor not in s:
        raise SystemExit("MAIN_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,helpers+anchor,1)

# Insert preflight after workspace creation, preserving any attachment staging that follows.
needle='''    workspace=Path("/home/ubuntu/Central/work")/trabajo
    workspace.mkdir(parents=True,exist_ok=True)
'''
replacement='''    workspace=Path("/home/ubuntu/Central/work")/trabajo
    workspace.mkdir(parents=True,exist_ok=True)
    started=time.time()
    checks=preflight(workspace)
    failed_checks=[x for x in checks if not x["ok"]]
    if failed_checks:
        reason="PREFLIGHT_FAILED: "+ "; ".join(x["name"]+"="+x["detail"] for x in failed_checks)
        emit_failure(trabajo,workspace,started,reason,checks=checks)
'''
if 'failed_checks=[x for x in checks if not x["ok"]]' not in s:
    if needle not in s:
        raise SystemExit("WORKSPACE_ANCHOR_NOT_FOUND")
    s=s.replace(needle,replacement,1)

# Remove later duplicate started=time.time() if present after attachment staging.
# Keep the first one inserted above.
parts=s.split('started=time.time()')
if len(parts)>2:
    s=parts[0]+'started=time.time()'+''.join(parts[1:]).replace('started=time.time()','',1)

# Wrap subprocess.run timeout and unexpected launch errors.
old='''    cp=subprocess.run(
        cmd,
        env={**os.environ,"PYTHONPATH":str(NATIVE)},
        text=True,capture_output=True,timeout=240
    )
    ended=time.time()
'''
new='''    try:
        cp=subprocess.run(
            cmd,
            env={**os.environ,"PYTHONPATH":str(NATIVE)},
            text=True,capture_output=True,timeout=240
        )
    except subprocess.TimeoutExpired as e:
        emit_failure(
            trabajo,workspace,started,
            "NATIVE_EXECUTION_TIMEOUT_240S",
            checks=checks,
            stdout=(e.stdout or "") if isinstance(e.stdout,str) else "",
            stderr=(e.stderr or "") if isinstance(e.stderr,str) else "",
            attachments=locals().get("staged_attachments",[])
        )
    except Exception as e:
        emit_failure(
            trabajo,workspace,started,
            "NATIVE_EXECUTION_LAUNCH_FAILED: "+str(e),
            checks=checks,
            attachments=locals().get("staged_attachments",[])
        )
    ended=time.time()
'''
if 'NATIVE_EXECUTION_TIMEOUT_240S' not in s:
    if old not in s:
        raise SystemExit("SUBPROCESS_ANCHOR_NOT_FOUND")
    s=s.replace(old,new,1)

# Enrich normal error extraction.
old2='''        err=stderr or (None if cp.returncode==0 else f"returncode={cp.returncode}")
'''
new2='''        err=(
            (result_obj or {}).get("error")
            or (result_obj or {}).get("detail")
            or stderr
            or (None if cp.returncode==0 else f"returncode={cp.returncode}")
        )
'''
if old2 in s:
    s=s.replace(old2,new2,1)

# Add structured fields to native block if current executor exposes native dict.
native_old='''            "steps":(result_obj or {}).get("steps"),
'''
native_new='''            "steps":(result_obj or {}).get("steps"),
            "capability":(result_obj or {}).get("capability"),
            "model_ref":(result_obj or {}).get("model_ref"),
            "router_score":(result_obj or {}).get("router_score"),
            "attempts":(result_obj or {}).get("attempts"),
            "error":(result_obj or {}).get("error"),
'''
if '"router_score":(result_obj or {}).get("router_score")' not in s and native_old in s:
    s=s.replace(native_old,native_new,1)

# Add preflight to successful/final result.
result_anchor='''        "error":err,
'''
if '"preflight":checks,' not in s:
    if result_anchor not in s:
        raise SystemExit("RESULT_ERROR_ANCHOR_NOT_FOUND")
    s=s.replace(result_anchor,'''        "preflight":checks,
        "error":err,
''',1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$EXEC"
echo NATIVE_EXECUTOR_PREFLIGHT_SOURCE_OK

echo "=== 2. STATIC PREFLIGHT TEST ==="
python3 - <<'PY'
import importlib.util
spec=importlib.util.spec_from_file_location("ne","/home/ubuntu/Central/runtime/native_executor.py")
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
from pathlib import Path
checks=m.preflight(Path("/home/ubuntu/Central/work/PREFLIGHT-STATIC"))
print(checks)
assert checks and all(x["ok"] for x in checks),checks
print("NATIVE_PREFLIGHT_STATIC_OK")
PY

echo "=== 3. RESTART CENTRAL JOBS ==="
sudo systemctl restart central-jobs-api.service
for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8091/api/health >/tmp/preflight-health.json 2>/dev/null && break
  sleep 1
done
cat /tmp/preflight-health.json
echo
systemctl is-active central-jobs-api.service
echo CENTRAL_JOBS_PREFLIGHT_SERVICE_OK

echo "=== 4. LIVE CANARY ==="
RESP=$(curl -fsS --max-time 10 -H 'Content-Type: application/json'   -d '{"task":"Creá preflight-canary.txt con el texto PREFLIGHT_CANARY_OK, leelo y verificá que coincida exactamente.","source":"chat","project":"Central","conversation_id":"preflight-canary"}'   http://127.0.0.1:8091/api/jobs)
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
assert r.get("jugador")=="Central Native",r
checks=r.get("preflight") or []
assert checks and all(x.get("ok") for x in checks),r
n=r.get("native") or {}
assert n.get("status")=="ok",n
print("NATIVE_PREFLIGHT_LIVE_OK")
print("capability="+str(n.get("capability")))
print("model_ref="+str(n.get("model_ref")))
PY

grep -qx 'PREFLIGHT_CANARY_OK' "/home/ubuntu/Central/work/$JOB/preflight-canary.txt"
echo PREFLIGHT_CANARY_FILE_OK

echo CENTRAL_NATIVE_PREFLIGHT_V1_READY
echo "backup=$BACKUP"
