#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Interfaz/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/interfaz-attachments-syntax-fix-$STAMP

mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py.broken"

echo "=== 1. REPAIR BROKEN NEWLINE LITERALS FROM ATTACHMENTS PATCH ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

# Repair the exact multiline string fragments accidentally materialized by project 169.
repls = {
'''parts.append("Imagen "+a["original_name"]+":
"+analyze_image_attachment(a,prompt or "Describí lo relevante de esta imagen."))''':
'''parts.append("Imagen "+a["original_name"]+":\\n"+analyze_image_attachment(a,prompt or "Describí lo relevante de esta imagen."))''',

'''parts.append("Archivo "+a["original_name"]+":
"+txt)''':
'''parts.append("Archivo "+a["original_name"]+":\\n"+txt)''',

'''return "

".join(parts)''':
'''return "\\n\\n".join(parts)''',

'''msgs[-1]["content"]=msgs[-1]["content"]+"

[CONTEXTO DE ADJUNTOS]
"+extra_context''':
'''msgs[-1]["content"]=msgs[-1]["content"]+"\\n\\n[CONTEXTO DE ADJUNTOS]\\n"+extra_context''',

'''effective=text+("

[CONTEXTO DE ADJUNTOS]
"+extra if extra else "")''':
'''effective=text+("\\n\\n[CONTEXTO DE ADJUNTOS]\\n"+extra if extra else "")''',
}

for old,new in repls.items():
    if old in s:
        s=s.replace(old,new)

p.write_text(s,encoding="utf-8")
PY

echo "=== 2. COMPILE CHECK ==="
python3 -m py_compile "$SERVER"
echo INTERFAZ_SERVER_SYNTAX_OK

echo "=== 3. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/interfaz-syntax-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/interfaz-syntax-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_SERVICE_RECOVERED_OK

echo "=== 4. VERIFY ATTACHMENTS PATCH MARKERS ==="
grep -q '/api/attachments' "$SERVER"
grep -q 'id="attach"' "$SERVER"
grep -q 'def attachment_context' "$SERVER"
echo ATTACHMENTS_PATCH_MARKERS_OK

echo "=== 5. RUN ATTACHMENTS V1 AGAIN ==="
bash /opt/corex/repo/projects/169-interfaz-attachments-v1.sh

echo INTERFAZ_ATTACHMENTS_SYNTAX_FIX_READY
echo "backup=$BACKUP"
