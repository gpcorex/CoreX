#!/usr/bin/env bash
set -euo pipefail

APP=/home/ubuntu/Central/runtime/jobs_api.py
CANON=/home/ubuntu/Central/canon/JOBS_API_V1.md
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/jobs-api-regularize-$STAMP

mkdir -p "$BACKUP" /home/ubuntu/Central/canon
cp -a "$APP" "$BACKUP/jobs_api.py"

python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Central/runtime/jobs_api.py")
s=p.read_text()

repls = {
    'job["status"]="EJECUTANDO"\n    job["started_at"]=now()':
    'job["status"]="ANALIZANDO"\n    save_job(job)\n    job["status"]="EJECUTANDO"\n    job["started_at"]=now()',

    '"contexto":{"source":"gemini","mode":"fast"}':
    '"contexto":{"source":"central","mode":"fast"}',

    '"source":job.get("source","gemini"),':
    '"source":job.get("source","chat"),',

    'job_id="TR-GEMINI-"+time.strftime("%Y%m%d-%H%M%S")+"-"+uuid.uuid4().hex[:6]':
    'job_id="TR-CENTRAL-"+time.strftime("%Y%m%d-%H%M%S")+"-"+uuid.uuid4().hex[:6]',

    '"source":str(body.get("source") or "gemini"),':
    '"source":str(body.get("source") or "chat"),',
}

for old,new in repls.items():
    if old not in s:
        raise SystemExit(f"PATCH_ANCHOR_NOT_FOUND: {old}")
    s=s.replace(old,new,1)

p.write_text(s)
PY

cat >"$CANON" <<'EOF'
# Central Jobs API v1

## Regla
Central recibe la intención del usuario y la convierte en un trabajo regularizado antes de ejecutar.

## Flujo
RECIBIDA -> ANALIZANDO -> EJECUTANDO -> PROBANDO -> COMPLETADA | ERROR

## Entrada mínima
POST /api/jobs

{
  "task": "orden del usuario",
  "source": "chat",
  "project": "nombre opcional",
  "conversation_id": "id opcional"
}

## Identidad
Los trabajos nuevos usan prefijo TR-CENTRAL-.

## Ejecución
- Acciones pequeñas y permitidas pueden resolverse por Central en modo DIRECT.
- El resto pasa por el executor de Central.
- OpenClaw ejecuta el trabajo ya estructurado por Central.
- Ninguna capa de interfaz debe programar directamente contra la VM.

## Criterio de cierre
Un trabajo sólo queda COMPLETADA cuando la ejecución devuelve CENTRAL_STATUS=COMPLETADO y la verificación requerida fue realizada.
EOF

chown ubuntu:ubuntu "$APP" "$CANON"
chmod 755 "$APP"

python3 -m py_compile "$APP"

systemctl restart central-jobs-api.service

for i in $(seq 1 20); do
  if curl -fsS --max-time 2 http://127.0.0.1:8091/api/health >/tmp/central-jobs-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done

echo "=== HEALTH ==="
cat /tmp/central-jobs-health.json
echo

echo "=== CONTRACT MARKERS ==="
grep -nE 'TR-CENTRAL|ANALIZANDO|source.*chat|source.*central' "$APP" | head -20

echo "=== DIRECT SMOKE ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json'   -d '{"task":"Creá /tmp/central-contract-smoke.txt con el texto CENTRAL_CONTRACT_OK y verificá","source":"chat","project":"Central","conversation_id":"contract-smoke"}'   http://127.0.0.1:8091/api/jobs)
echo "$RESP"
JOB_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP")

for i in $(seq 1 30); do
  OUT=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB_ID")
  STATUS=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
  case "$STATUS" in
    COMPLETADA|ERROR) break ;;
  esac
  sleep 1
done

echo "$OUT"
python3 - <<'PY' <<<"$OUT"
import json,sys
o=json.load(sys.stdin)
j=o["job"]
assert j["id"].startswith("TR-CENTRAL-"), j["id"]
assert j["status"]=="COMPLETADA", j
assert j.get("source")=="chat", j
assert j.get("result",{}).get("resultado")=="CENTRAL_STATUS=COMPLETADO", j
print("CENTRAL_JOBS_CONTRACT_OK")
PY

echo "backup=$BACKUP"
echo CENTRAL_JOBS_REGULARIZED
