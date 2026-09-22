#!/usr/bin/env bash
set -euo pipefail

SERVER=/home/ubuntu/Interfaz/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/interfaz-attachments-import-fix-$STAMP

mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. NORMALIZE INTERFAZ IMPORTS FOR ATTACHMENTS PATCH ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

target="import base64, json, os, re, sqlite3, subprocess, tempfile, time, urllib.request, urllib.error, uuid"

lines=s.splitlines()
found=False
for i,line in enumerate(lines):
    if line.startswith("import ") and all(x in line for x in ("base64","json","sqlite3","subprocess","urllib.request","uuid")):
        lines[i]=target
        found=True
        break

if not found:
    # Add the exact import expected by project 169, without touching __future__.
    insert_at=2 if len(lines)>1 and lines[1].startswith("from __future__") else 1
    lines.insert(insert_at,target)

p.write_text("\n".join(lines)+"\n",encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
grep -n '^import ' "$SERVER" | head -5
echo INTERFAZ_IMPORT_NORMALIZED_OK

echo "=== 2. RUN ATTACHMENTS V1 PATCH AGAIN ==="
bash /opt/corex/repo/projects/169-interfaz-attachments-v1.sh

echo INTERFAZ_ATTACHMENTS_IMPORT_FIX_READY
echo "backup=$BACKUP"
