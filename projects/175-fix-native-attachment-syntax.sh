#!/usr/bin/env bash
set -euo pipefail

EXEC=/home/ubuntu/Central/runtime/native_executor.py
NATIVE=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-attachment-syntax-fix-$STAMP

mkdir -p "$BACKUP"
cp -a "$EXEC" "$BACKUP/native_executor.py.broken"

echo "=== 1. REPAIR NATIVE EXECUTOR STRING LITERALS ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/runtime/native_executor.py")
s=p.read_text(encoding="utf-8")

repls={
'''            instruction += "

[ARCHIVOS ADJUNTOS DISPONIBLES EN EL WORKSPACE]
"
''':
'''            instruction += "\\n\\n[ARCHIVOS ADJUNTOS DISPONIBLES EN EL WORKSPACE]\\n"
''',
'''            instruction += "
".join("- "+x["workspace_path"]+" ("+x["name"]+")" for x in staged_attachments)
''':
'''            instruction += "\\n".join("- "+x["workspace_path"]+" ("+x["name"]+")" for x in staged_attachments)
''',
}

for old,new in repls.items():
    if old in s:
        s=s.replace(old,new)

# Fallback structural repair for any remaining broken instruction += quote/newline pattern.
lines=s.splitlines()
out=[]
i=0
while i < len(lines):
    line=lines[i]
    if line.strip()=='instruction += "' and i+3 < len(lines):
        if lines[i+1].strip()=='' and 'ARCHIVOS ADJUNTOS DISPONIBLES EN EL WORKSPACE' in lines[i+2]:
            indent=line[:len(line)-len(line.lstrip())]
            out.append(indent+'instruction += "\\n\\n[ARCHIVOS ADJUNTOS DISPONIBLES EN EL WORKSPACE]\\n"')
            i += 4
            continue
    if line.strip()=='instruction += "' and i+1 < len(lines):
        if lines[i+1].lstrip().startswith('".join("- "+x["workspace_path"]'):
            indent=line[:len(line)-len(line.lstrip())]
            out.append(indent+'instruction += "\\n".join("- "+x["workspace_path"]+" ("+x["name"]+")" for x in staged_attachments)')
            i += 2
            continue
    out.append(line)
    i += 1

p.write_text("\n".join(out)+"\n",encoding="utf-8")
PY

python3 -m py_compile "$EXEC"
echo NATIVE_EXECUTOR_SYNTAX_OK

echo "=== 2. VERIFY STAGING MARKERS ==="
grep -nE 'CENTRAL_ATTACHMENTS_B64|staged_attachments|ARCHIVOS ADJUNTOS' "$EXEC" | head -30
echo NATIVE_ATTACHMENT_STAGING_MARKERS_OK

echo "=== 3. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/op-att-v3-syntax-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/op-att-v3-syntax-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_SERVICE_OK

echo "=== 4. END-TO-END OPERATIONAL ATTACHMENT RETEST ==="
SRC=/tmp/operational-attachment-source.txt
printf 'ARCHIVO_OPERATIVO_731\n' > "$SRC"

REQ=/tmp/operational-attachment-upload.json
python3 - "$SRC" "$REQ" <<'PY'
import base64,json,sys
src,dst=sys.argv[1:]
with open(src,"rb") as f:b64=base64.b64encode(f.read()).decode()
with open(dst,"w",encoding="utf-8") as f:
    json.dump({"name":"entrada-operativa.txt","mime":"text/plain","data_base64":b64},f,separators=(",",":"))
PY

UP=$(curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @"$REQ" http://127.0.0.1:8791/api/attachments)
echo "$UP"
CID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["conversation_id"])' <<<"$UP")
AID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["attachment"]["id"])' <<<"$UP")

MSGREQ=/tmp/operational-attachment-message.json
python3 - "$CID" "$AID" "$MSGREQ" <<'PY'
import json,sys
cid,aid,dst=sys.argv[1:]
with open(dst,"w",encoding="utf-8") as f:
    json.dump({
      "conversation_id":cid,
      "text":"Creá el archivo resultado-adjunto.txt leyendo el archivo adjunto original y copiando exactamente su contenido. Después verificá que coincida.",
      "attachment_ids":[aid]
    },f,ensure_ascii=False)
PY

MSG=$(curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @"$MSGREQ" http://127.0.0.1:8791/api/message)
echo "$MSG"

JOB=$(MSG_JSON="$MSG" python3 - <<'PY'
import json,os
x=json.loads(os.environ["MSG_JSON"])
assert x["ok"] is True,x
assert x["mode"]=="job",x
print(x["job_id"])
PY
)

for i in $(seq 1 120); do
  OUT=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB")
  STATUS=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
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
atts=r.get("attachments") or []
assert atts,r
assert any(a.get("workspace_path")=="attachments/entrada-operativa.txt" for a in atts),atts
print("OPERATIONAL_ATTACHMENT_STAGED_OK")
PY

test -f "/home/ubuntu/Central/work/$JOB/attachments/entrada-operativa.txt"
grep -qx 'ARCHIVO_OPERATIVO_731' "/home/ubuntu/Central/work/$JOB/attachments/entrada-operativa.txt"
test -f "/home/ubuntu/Central/work/$JOB/resultado-adjunto.txt"
grep -qx 'ARCHIVO_OPERATIVO_731' "/home/ubuntu/Central/work/$JOB/resultado-adjunto.txt"
echo OPERATIONAL_ATTACHMENT_AGENT_USE_OK

cat >"$NATIVE/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "operational-attachments-v3-syntax-fix",
  "raw_attachment_staging": true,
  "workspace_directory": "attachments/",
  "agent_can_use_original_files": true,
  "active": true
}
EOF

echo CENTRAL_OPERATIONAL_ATTACHMENTS_V3_READY
echo "backup=$BACKUP"
