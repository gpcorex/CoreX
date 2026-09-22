#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Interfaz/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/job-error-diagnosis-fix-$STAMP
mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. REPAIR DIAGNOSIS FUNCTION SYNTAX ==="
python3 - <<'PY'
from pathlib import Path
import re

p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

pat=r'def diagnose_job_failure\(job\):.*?\nclass H\(BaseHTTPRequestHandler\):'
m=re.search(pat,s,flags=re.S)
if not m:
    raise SystemExit("DIAGNOSIS_FUNCTION_BLOCK_NOT_FOUND")

replacement='''def diagnose_job_failure(job):
    prompt = (
        "Analizá este trabajo fallido de Central. Explicá la causa concreta en lenguaje claro, "
        "y proponé la solución más directa y segura. No inventes datos que no estén en el job. "
        "Si falta información, decí exactamente qué falta. No ejecutes cambios.\\n\\n"
        "JOB FALLIDO:\\n"
        + json.dumps(job, ensure_ascii=False)[:14000]
    )
    payload={"messages":[{"role":"user","content":prompt}]}
    env=dict(os.environ)
    env["PYTHONPATH"]="/home/ubuntu/Central/native_v1"
    cp=subprocess.run(
        ["/usr/bin/python3","/home/ubuntu/Central/native_v1/native_chat.py"],
        input=json.dumps(payload,ensure_ascii=False),
        text=True,capture_output=True,timeout=120,env=env
    )
    if cp.returncode!=0:
        raise RuntimeError("JOB_DIAGNOSIS_FAILED:"+(cp.stderr or cp.stdout)[-800:])
    out=json.loads(cp.stdout)
    if not out.get("ok"):
        raise RuntimeError(str(out.get("error") or "JOB_DIAGNOSIS_FAILED"))
    return str(out.get("answer") or "").strip()

class H(BaseHTTPRequestHandler):'''

s=s[:m.start()]+replacement+s[m.end():]
p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo JOB_DIAGNOSIS_SYNTAX_REPAIRED_OK

echo "=== 2. VERIFY PATCH COMPONENTS ==="
grep -q 'def diagnose_job_failure' "$SERVER"
grep -q 'JOB_NOT_IN_ERROR' "$SERVER"
grep -q 'jobErrorDetail' "$SERVER"
grep -q 'Diagnóstico y solución sugerida' "$SERVER"
grep -q 'api/job-diagnose' "$SERVER"
echo JOB_DIAGNOSIS_COMPONENTS_PRESENT_OK

echo "=== 3. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/jobdiag-fix-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/jobdiag-fix-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_JOB_DIAGNOSIS_SERVICE_OK

echo "=== 4. PUBLIC UI MARKERS ==="
PUB=$(curl -fsS --max-time 20 https://cen-tral.duckdns.org/interfaz/)
grep -q 'jobErrorDetail' <<<"$PUB"
grep -q 'Diagnóstico y solución sugerida' <<<"$PUB"
grep -q 'api/job-diagnose' <<<"$PUB"
echo JOB_ERROR_DIAGNOSIS_PUBLIC_UI_OK

echo CENTRAL_JOB_ERROR_DIAGNOSIS_V1_READY
echo "backup=$BACKUP"
