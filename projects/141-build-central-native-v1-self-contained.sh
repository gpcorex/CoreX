#!/usr/bin/env bash
set -euo pipefail

CENTRAL=http://127.0.0.1:8091
DEST=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-v1-$STAMP

mkdir -p "$BACKUP"

echo "=== SUBMIT SELF-CONTAINED BUILD JOB ==="
TASK=$(cat <<'EOF'
Construí dentro de TU WORKSPACE una carpeta llamada native_v1 con un paquete Python completo.

CONTRATO OBLIGATORIO:

OBJETIVO
Construir dentro de Central el reemplazo progresivo de OpenClaw.

ARQUITECTURA
Interfaz -> Central -> Enrutador -> Provider -> Modelo -> Herramientas -> VM

MÓDULOS MÍNIMOS
- providers.py: clientes OpenAI-compatible para Groq y OpenRouter.
- router.py: selección simple por rol y fallback.
- radar.py: descubrimiento/verificación de modelos accesibles por provider.
- tools.py: herramientas locales controladas: read, write, edit, exec, process.
- agent.py: bucle modelo -> tool call -> resultado -> modelo.
- config.py: carga de claves/model roster sin exponer secretos.
- cli.py: entrada de prueba para ejecutar una tarea.
- tests/: pruebas unitarias mínimas.

FUENTES DE CONFIGURACIÓN QUE EL CÓDIGO GENERADO DEBE SOPORTAR EN EJECUCIÓN
- Groq key: /home/ubuntu/Claves/prov/groq.key
- OpenRouter key: /home/ubuntu/Claves/providers/openrouter.key
- Roster: /home/ubuntu/Central/config/model-roster.json

REGLAS DE CONSTRUCCIÓN
- No leas archivos fuera de tu workspace durante esta construcción.
- No escribas fuera de tu workspace.
- No modifiques servicios.
- No modifiques archivos activos de Central.
- No toques Interfaz ni Caddy.
- No uses OpenClaw como dependencia del código generado.
- Usá sólo librería estándar de Python salvo necesidad demostrada.
- Las herramientas deben validar rutas y timeouts.
- El bucle agente debe tener máximo de pasos configurable.
- El router debe soportar roles: rapido, tecnico, fuerte y fallback.
- El Radar debe poder listar modelos Groq y OpenRouter y devolver sólo metadatos, nunca claves.
- El cliente de providers debe soportar APIs OpenAI-compatible.
- El código debe quedar desacoplado del provider específico.

ARCHIVOS OBLIGATORIOS DENTRO DE ./native_v1
README.md
__init__.py
config.py
providers.py
router.py
radar.py
tools.py
agent.py
cli.py
tests/
BUILD_REPORT.json

PRUEBAS OBLIGATORIAS
- python3 -m py_compile de todos los módulos.
- pruebas unitarias locales sin llamadas externas obligatorias.
- validar que router/radar/tools/agent puedan importarse.
- validar que tools rechace rutas fuera de una raíz permitida.
- validar que el agente respete max_steps.

BUILD_REPORT.json debe tener exactamente esta estructura mínima:
{
  "ok": true,
  "files": ["..."],
  "tests": "passed",
  "notes": "..."
}

CRITERIO DE ÉXITO
Sólo terminá con CENTRAL_STATUS=COMPLETADO si:
1. todos los archivos existen;
2. compilan;
3. las pruebas pasan;
4. BUILD_REPORT.json es válido;
5. no escribiste fuera del workspace.
EOF
)

RESP=$(python3 - "$TASK" <<'PY'
import json,sys,urllib.request
task=sys.argv[1]
payload={
  "task":task,
  "source":"central-bootstrap",
  "project":"Central Native V1",
  "conversation_id":"native-v1-bootstrap-2"
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

echo "$RESP"
JOB_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP")
WORK=/home/ubuntu/Central/work/$JOB_ID/native_v1

echo "=== WAIT FOR BUILD ==="
for i in $(seq 1 420); do
  OUT=$(curl -fsS --max-time 5 "$CENTRAL/api/jobs/$JOB_ID")
  STATUS=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
  printf '\rstatus=%s elapsed=%ss' "$STATUS" "$i"
  case "$STATUS" in COMPLETADA|ERROR) break ;; esac
  sleep 1
done
echo
echo "$OUT"

STATUS=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
[ "$STATUS" = "COMPLETADA" ] || { echo "BUILD_JOB_FAILED"; exit 1; }

echo "=== VERIFY GENERATED PACKAGE ==="
for f in README.md __init__.py config.py providers.py router.py radar.py tools.py agent.py cli.py BUILD_REPORT.json; do
  [ -s "$WORK/$f" ] || { echo "MISSING $WORK/$f"; exit 1; }
done
[ -d "$WORK/tests" ] || { echo "MISSING tests"; exit 1; }

python3 -m py_compile "$WORK"/config.py "$WORK"/providers.py "$WORK"/router.py "$WORK"/radar.py "$WORK"/tools.py "$WORK"/agent.py "$WORK"/cli.py

if find "$WORK/tests" -type f -name 'test_*.py' | grep -q .; then
  PYTHONPATH="$(dirname "$WORK")" python3 -m unittest discover -s "$WORK/tests" -p 'test_*.py'
fi

python3 - "$WORK/BUILD_REPORT.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8"))
assert x.get("ok") is True, x
assert x.get("tests")=="passed", x
assert isinstance(x.get("files"),list) and x["files"], x
print("BUILD_REPORT_OK")
PY

echo "=== INSTALL INACTIVE NATIVE STACK ==="
if [ -d "$DEST" ]; then
  cp -a "$DEST" "$BACKUP/native_v1"
fi
rm -rf "$DEST"
cp -a "$WORK" "$DEST"
chown -R ubuntu:ubuntu "$DEST"

echo "=== FINAL VERIFY ==="
python3 -m py_compile "$DEST"/*.py
find "$DEST" -maxdepth 2 -type f | sort

echo "CENTRAL_NATIVE_V1_BUILT"
echo "job_id=$JOB_ID"
echo "installed=$DEST"
echo "backup=$BACKUP"
echo "NOTE=Still inactive; current production flow unchanged."
