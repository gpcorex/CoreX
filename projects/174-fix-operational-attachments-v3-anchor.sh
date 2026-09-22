#!/usr/bin/env bash
set -euo pipefail

INTERFAZ=/home/ubuntu/Interfaz/server.py
EXEC=/home/ubuntu/Central/runtime/native_executor.py
NATIVE=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/operational-attachments-v3-fix-$STAMP

mkdir -p "$BACKUP"
cp -a "$INTERFAZ" "$BACKUP/interfaz-server.py"
cp -a "$EXEC" "$BACKUP/native_executor.py"

echo "=== 1. ROBUST PATCH INTERFAZ OPERATIONAL ATTACHMENTS ==="
python3 - <<'PY'
from pathlib import Path
import re
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

if 'CENTRAL_ATTACHMENTS_B64:' not in s:
    pat=re.compile(
        r'(?P<indent>\s*)effective=text\+\((?P<expr>.*?)\)\n'
        r'(?P=indent)if is_operational\(text\):',
        re.S
    )
    m=pat.search(s)
    if not m:
        # Alternate: locate the exact line structurally and insert after it.
        lines=s.splitlines()
        idx=None
        for i,line in enumerate(lines):
            if 'effective=text+' in line:
                idx=i
                break
        if idx is None:
            raise SystemExit("EFFECTIVE_TASK_LINE_NOT_FOUND")
        indent=lines[idx][:len(lines[idx])-len(lines[idx].lstrip())]
        block=[
            indent+'operational_task=effective',
            indent+'if attachments:',
            indent+'    manifest=[{"path":a["path"],"name":a["original_name"],"mime":a["mime"],"size":a["size"]} for a in attachments]',
            indent+'    encoded=base64.urlsafe_b64encode(json.dumps(manifest,ensure_ascii=False).encode("utf-8")).decode("ascii")',
            indent+'    operational_task=effective+"\\n[[CENTRAL_ATTACHMENTS_B64:"+encoded+"]]"',
        ]
        lines[idx+1:idx+1]=block
        s="\n".join(lines)+"\n"
    else:
        indent=m.group("indent")
        original=m.group(0)
        effective_line=original[:original.rfind("\n"+indent+"if is_operational(text):")]
        replacement=effective_line+"\n"+indent+"operational_task=effective\n"+indent+"if attachments:\n"+indent+'    manifest=[{"path":a["path"],"name":a["original_name"],"mime":a["mime"],"size":a["size"]} for a in attachments]\n'+indent+'    encoded=base64.urlsafe_b64encode(json.dumps(manifest,ensure_ascii=False).encode("utf-8")).decode("ascii")\n'+indent+'    operational_task=effective+"\\n[[CENTRAL_ATTACHMENTS_B64:"+encoded+"]]"\n'+indent+"if is_operational(text):"
        s=s[:m.start()]+replacement+s[m.end():]

# Replace only operational payload task assignment following is_operational.
pat2=re.compile(r'(if is_operational\(text\):\s*\n\s*payload=\{\s*\n\s*"task":)effective(,)',re.S)
s,n=pat2.subn(r'\1operational_task\2',s,count=1)
if n==0 and '"task":operational_task' not in s:
    raise SystemExit("OPERATIONAL_PAYLOAD_TASK_NOT_FOUND")

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$INTERFAZ"
grep -nE 'CENTRAL_ATTACHMENTS_B64|operational_task' "$INTERFAZ" | head -10
echo INTERFAZ_OPERATIONAL_ATTACHMENT_PATCH_OK

echo "=== 2. ROBUST PATCH CENTRAL NATIVE ATTACHMENT STAGING ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/runtime/native_executor.py")
s=p.read_text(encoding="utf-8")

# imports
for old,new in [
    ('import json, os, subprocess, sys, time, uuid','import base64, json, os, re, shutil, subprocess, sys, time, uuid'),
    ('import json, os, re, subprocess, sys, time, uuid','import base64, json, os, re, shutil, subprocess, sys, time, uuid'),
]:
    if old in s:
        s=s.replace(old,new,1)
        break
if 'import base64' not in s:
    raise SystemExit("NATIVE_IMPORTS_NOT_PATCHED")

if 'staged_attachments=[]' not in s:
    marker='''    workspace=Path("/home/ubuntu/Central/work")/trabajo
    workspace.mkdir(parents=True,exist_ok=True)
'''
    if marker not in s:
        raise SystemExit("WORKSPACE_BLOCK_NOT_FOUND")

    block=marker+'''
    staged_attachments=[]
    attachment_marker=re.search(r"\\n?\\[\\[CENTRAL_ATTACHMENTS_B64:([A-Za-z0-9_=-]+)\\]\\]\\s*$",instruction)
    if attachment_marker:
        encoded=attachment_marker.group(1)
        instruction=instruction[:attachment_marker.start()].rstrip()
        try:
            manifest=json.loads(base64.urlsafe_b64decode(encoded.encode("ascii")).decode("utf-8"))
        except Exception as e:
            raise SystemExit("INVALID_ATTACHMENT_MANIFEST:"+str(e))

        source_root=Path("/home/ubuntu/Interfaz/data/attachments").resolve()
        target_root=workspace/"attachments"
        target_root.mkdir(parents=True,exist_ok=True)

        for idx,item in enumerate(manifest[:8],1):
            src=Path(str(item.get("path") or "")).resolve()
            try:
                src.relative_to(source_root)
            except Exception:
                raise SystemExit("ATTACHMENT_OUTSIDE_ALLOWED_ROOT")
            if not src.is_file():
                raise SystemExit("ATTACHMENT_FILE_MISSING:"+str(src))

            raw_name=Path(str(item.get("name") or src.name)).name
            safe_name=re.sub(r"[^A-Za-z0-9._() -]+","_",raw_name).strip(" .") or f"adjunto-{idx}"
            dst=target_root/safe_name
            if dst.exists():
                dst=target_root/f"{dst.stem}-{idx}{dst.suffix}"
            shutil.copy2(src,dst)
            staged_attachments.append({
                "name":raw_name,
                "workspace_path":str(dst.relative_to(workspace)),
                "mime":str(item.get("mime") or ""),
                "size":dst.stat().st_size,
            })

        if staged_attachments:
            instruction += "\n\n[ARCHIVOS ADJUNTOS DISPONIBLES EN EL WORKSPACE]\n"
            instruction += "\n".join("- "+x["workspace_path"]+" ("+x["name"]+")" for x in staged_attachments)
'''
    s=s.replace(marker,block,1)

if '"attachments":staged_attachments' not in s:
    marker2='''        "workspace":str(workspace),
'''
    if marker2 not in s:
        raise SystemExit("RESULT_WORKSPACE_FIELD_NOT_FOUND")
    s=s.replace(marker2,marker2+'''        "attachments":staged_attachments,
''',1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$EXEC"
grep -nE 'staged_attachments|CENTRAL_ATTACHMENTS_B64' "$EXEC" | head -20
echo CENTRAL_NATIVE_ATTACHMENT_STAGING_OK

echo "=== 3. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/op-att-v3-fix-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/op-att-v3-fix-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_OPERATIONAL_ATTACHMENTS_SERVICE_OK

echo "=== 4. END-TO-END OPERATIONAL ATTACHMENT TEST ==="
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
  "build": "operational-attachments-v3-fix",
  "raw_attachment_staging": true,
  "workspace_directory": "attachments/",
  "source_root_restricted": "/home/ubuntu/Interfaz/data/attachments",
  "max_files_per_job": 8,
  "agent_can_use_original_files": true,
  "active": true
}
EOF

echo CENTRAL_OPERATIONAL_ATTACHMENTS_V3_READY
echo "backup=$BACKUP"
