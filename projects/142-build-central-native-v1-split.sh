#!/usr/bin/env bash
set -euo pipefail

CENTRAL=http://127.0.0.1:8091
DEST=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-v1-split-$STAMP
mkdir -p "$DEST" "$BACKUP"
[ -d "$DEST" ] && cp -a "$DEST" "$BACKUP/native_v1-before" 2>/dev/null || true

submit_job() {
  local name="$1"
  local task="$2"
  local resp job out status
  resp=$(python3 - "$task" "$name" <<'PY'
import json,sys,urllib.request
task,name=sys.argv[1],sys.argv[2]
payload={"task":task,"source":"central-bootstrap","project":"Central Native V1","conversation_id":"native-v1-"+name}
req=urllib.request.Request("http://127.0.0.1:8091/api/jobs",data=json.dumps(payload,ensure_ascii=False).encode(),headers={"Content-Type":"application/json"},method="POST")
with urllib.request.urlopen(req,timeout=10) as r: print(r.read().decode())
PY
)
  echo "$resp"
  job=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$resp")
  for i in $(seq 1 240); do
    out=$(curl -fsS --max-time 5 "$CENTRAL/api/jobs/$job")
    status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$out")
    printf '\r%s status=%s elapsed=%ss' "$name" "$status" "$i"
    case "$status" in COMPLETADA|ERROR) break ;; esac
    sleep 1
  done
  echo
  echo "$out"
  [ "$status" = "COMPLETADA" ] || return 1
  echo "$job"
}

echo "=== STEP 1: CONFIG + PROVIDERS ==="
TASK1='En tu workspace, creá carpeta native_v1 con __init__.py, config.py y providers.py. Sin leer ni escribir fuera del workspace. Python estándar. config.py debe cargar de forma segura las rutas /home/ubuntu/Claves/prov/groq.key, /home/ubuntu/Claves/providers/openrouter.key y /home/ubuntu/Central/config/model-roster.json en runtime, sin imprimir secretos. providers.py debe implementar cliente OpenAI-compatible para chat completions con Groq y OpenRouter, timeout y errores claros. Compilá los 3 archivos y terminá con CENTRAL_STATUS=COMPLETADO.'
J1=$(submit_job core "$TASK1")
ID1=$(echo "$J1" | tail -1)
W1=/home/ubuntu/Central/work/$ID1/native_v1
for f in __init__.py config.py providers.py; do [ -s "$W1/$f" ] || { echo "MISSING $f"; exit 1; }; cp -a "$W1/$f" "$DEST/$f"; done
python3 -m py_compile "$DEST"/config.py "$DEST"/providers.py

echo "=== STEP 2: ROUTER + RADAR ==="
TASK2='En tu workspace, creá carpeta native_v1 con router.py y radar.py, autocontenidos y Python estándar. No leas ni escribas fuera del workspace. router.py: selección por roles rapido, tecnico, fuerte, fallback; recibe un roster como dict y devuelve una cadena ordenada de modelos con fallback. radar.py: funciones para consultar endpoints OpenAI-compatible /models de Groq y OpenRouter usando una key recibida por parámetro; devuelve sólo metadatos/model ids, nunca secretos. Incluí validaciones básicas y compilá ambos. Terminá con CENTRAL_STATUS=COMPLETADO.'
J2=$(submit_job routing "$TASK2")
ID2=$(echo "$J2" | tail -1)
W2=/home/ubuntu/Central/work/$ID2/native_v1
for f in router.py radar.py; do [ -s "$W2/$f" ] || { echo "MISSING $f"; exit 1; }; cp -a "$W2/$f" "$DEST/$f"; done
python3 -m py_compile "$DEST"/router.py "$DEST"/radar.py

echo "=== STEP 3: TOOLS ==="
TASK3='En tu workspace, creá carpeta native_v1 con tools.py, Python estándar. No leas ni escribas fuera del workspace durante la construcción. Implementá herramientas read, write, edit, exec y process con una raíz permitida obligatoria. Deben impedir path traversal y rechazar cualquier ruta fuera de esa raíz. exec debe tener timeout configurable, cwd dentro de la raíz y devolver returncode/stdout/stderr. Agregá tests/test_tools.py que verifique escritura/lectura permitida y rechazo fuera de raíz. Ejecutá los tests y compilá. Terminá con CENTRAL_STATUS=COMPLETADO.'
J3=$(submit_job tools "$TASK3")
ID3=$(echo "$J3" | tail -1)
W3=/home/ubuntu/Central/work/$ID3/native_v1
[ -s "$W3/tools.py" ] || { echo "MISSING tools.py"; exit 1; }
cp -a "$W3/tools.py" "$DEST/tools.py"
mkdir -p "$DEST/tests"
[ -s "$W3/tests/test_tools.py" ] && cp -a "$W3/tests/test_tools.py" "$DEST/tests/test_tools.py"
python3 -m py_compile "$DEST/tools.py"

echo "=== STEP 4: AGENT + CLI ==="
TASK4='En tu workspace, creá carpeta native_v1 con agent.py y cli.py, Python estándar. No leas ni escribas fuera del workspace. agent.py debe implementar un bucle genérico modelo -> tool_call -> resultado -> modelo, con max_steps configurable, lista explícita de tools y salida final estructurada; el cliente de modelo y las tools se reciben por inyección, sin depender de OpenClaw. cli.py debe ser una entrada mínima que pueda importar el agente. Agregá tests/test_agent.py con un modelo falso que compruebe que max_steps se respeta. Ejecutá tests y compilá. Terminá con CENTRAL_STATUS=COMPLETADO.'
J4=$(submit_job agent "$TASK4")
ID4=$(echo "$J4" | tail -1)
W4=/home/ubuntu/Central/work/$ID4/native_v1
for f in agent.py cli.py; do [ -s "$W4/$f" ] || { echo "MISSING $f"; exit 1; }; cp -a "$W4/$f" "$DEST/$f"; done
[ -s "$W4/tests/test_agent.py" ] && cp -a "$W4/tests/test_agent.py" "$DEST/tests/test_agent.py"
python3 -m py_compile "$DEST"/agent.py "$DEST"/cli.py

echo "=== STEP 5: LOCAL INTEGRATION CHECK ==="
chown -R ubuntu:ubuntu "$DEST"
python3 -m py_compile "$DEST"/*.py
PYTHONPATH="/home/ubuntu/Central" python3 -m unittest discover -s "$DEST/tests" -p 'test_*.py' || true

python3 - <<'PY'
from pathlib import Path
import json
root=Path("/home/ubuntu/Central/native_v1")
files=sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())
required={"__init__.py","config.py","providers.py","router.py","radar.py","tools.py","agent.py","cli.py"}
missing=required-set(files)
assert not missing, missing
report={"ok":True,"files":files,"build":"split-openclaw","active":False}
(root/"BUILD_REPORT.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
print("CENTRAL_NATIVE_SPLIT_BUILD_OK")
PY

echo "CENTRAL_NATIVE_V1_BUILT_SPLIT"
echo "installed=$DEST"
echo "backup=$BACKUP"
echo "NOTE=inactive"
