#!/usr/bin/env bash
set -euo pipefail

CENTRAL=http://127.0.0.1:8091
DEST=/home/ubuntu/Central/native_v1
CANON=/home/ubuntu/Central/canon/NATIVE_AGENT_V1.md
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-v1-$STAMP

mkdir -p "$(dirname "$CANON")" "$BACKUP"

cat >"$CANON" <<'EOF'
# Central Native Agent V1

## Objetivo
Construir dentro de Central el reemplazo progresivo de OpenClaw.

## Arquitectura
Interfaz -> Central -> Enrutador -> Provider -> Modelo -> Herramientas -> VM

## Módulos mínimos
- providers.py: clientes OpenAI-compatible para Groq y OpenRouter.
- router.py: selección simple por rol y fallback.
- radar.py: descubrimiento/verificación de modelos accesibles por provider.
- tools.py: herramientas locales controladas (read, write, edit, exec, process).
- agent.py: bucle modelo -> tool call -> resultado -> modelo.
- config.py: carga de claves/model roster sin exponer secretos.
- cli.py: entrada de prueba para ejecutar una tarea.
- tests/: pruebas unitarias mínimas.

## Reglas
- No escribir fuera del workspace de trabajo durante la construcción.
- No modificar servicios ni configuración activa.
- No tocar Interfaz, Caddy ni Central Jobs.
- No depender de OpenClaw en el código generado.
- Usar sólo librería estándar de Python salvo necesidad demostrada.
- Leer claves existentes desde:
  - /home/ubuntu/Claves/prov/groq.key
  - /home/ubuntu/Claves/providers/openrouter.key
- Leer roster desde:
  - /home/ubuntu/Central/config/model-roster.json
- Las herramientas deben validar rutas y timeouts.
- El bucle agente debe tener máximo de pasos configurable.
- El router debe soportar roles: rapido, tecnico, fuerte y fallback.
- El Radar debe poder listar modelos Groq y OpenRouter y devolver sólo metadatos, nunca claves.

## Criterio de éxito
El paquete se genera completo dentro del workspace, compila, sus tests locales pasan y queda listo para ser instalado por un paso posterior controlado.
EOF

echo "=== SUBMIT BUILD JOB TO CENTRAL ==="
TASK=$(cat <<'EOF'
Dentro de TU WORKSPACE de este trabajo, construí una carpeta llamada native_v1 con un paquete Python completo que implemente exactamente el contrato de /home/ubuntu/Central/canon/NATIVE_AGENT_V1.md.

IMPORTANTE:
- No escribas fuera de tu workspace.
- No modifiques servicios.
- No modifiques archivos activos de Central.
- No uses OpenClaw como dependencia del código generado.
- Generá todos los archivos necesarios dentro de ./native_v1.
- Incluí README.md, __init__.py, config.py, providers.py, router.py, radar.py, tools.py, agent.py, cli.py y tests/.
- Ejecutá python3 -m py_compile sobre los módulos.
- Ejecutá las pruebas.
- Dejá un BUILD_REPORT.json dentro de ./native_v1 con:
  {"ok":true,"files":[...],"tests":"passed","notes":"..."}
- Terminá con CENTRAL_STATUS=COMPLETADO solamente si todo lo anterior quedó verificado.
EOF
)

RESP=$(python3 - <<'PY' "$TASK"
import json,sys,urllib.request
task=sys.argv[1]
payload={
  "task":task,
  "source":"central-bootstrap",
  "project":"Central Native V1",
  "conversation_id":"native-v1-bootstrap"
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

python3 - "$WORK/BUILD_REPORT.json" <<'PY'
import json,sys
p=sys.argv[1]
x=json.load(open(p,encoding="utf-8"))
assert x.get("ok") is True, x
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
find "$DEST" -maxdepth 2 -type f | sort
python3 -m py_compile "$DEST"/*.py

echo "CENTRAL_NATIVE_V1_BUILT"
echo "job_id=$JOB_ID"
echo "installed=$DEST"
echo "backup=$BACKUP"
echo "NOTE=Not activated; current Interfaz/Central flow remains unchanged."
