#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/ingest_v1
PROJECTS=/home/ubuntu/Central/projects
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/ingest-v1-perms-fix-$STAMP
mkdir -p "$BACKUP"
cp -a "$ROOT/ingest.py" "$BACKUP/ingest.py"

echo "=== 1. FIX PROJECTS DIRECTORY OWNERSHIP ==="
sudo mkdir -p "$PROJECTS"
sudo chown -R ubuntu:ubuntu "$PROJECTS"
sudo chmod 755 "$PROJECTS"
test -w "$PROJECTS"
echo CENTRAL_PROJECTS_WRITABLE_OK

echo "=== 2. HARDEN INGEST FOR DIRECTORY CREATION ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/ingest_v1/ingest.py")
s=p.read_text(encoding="utf-8")

old='''    root=PROJECTS/project_id
    src=root/"source"
    canon=root/"canon"
    work=root/"work"
    for d in (src,canon,work): d.mkdir(parents=True,exist_ok=True)
'''
new='''    PROJECTS.mkdir(parents=True,exist_ok=True)
    root=PROJECTS/project_id
    src=root/"source"
    canon=root/"canon"
    work=root/"work"
    for d in (src,canon,work):
        d.mkdir(parents=True,exist_ok=True)
'''
if old not in s:
    raise SystemExit("INGEST_PROJECT_DIR_ANCHOR_NOT_FOUND")

p.write_text(s.replace(old,new,1),encoding="utf-8")
PY

python3 -m py_compile "$ROOT/ingest.py"
echo INGEST_V1_PERMISSIONS_PATCH_OK

echo "=== 3. RETEST LOCAL FILE INGEST ==="
TMP=/tmp/central-ingest-v1-demo.apk
printf 'CENTRAL_INGEST_V1_DEMO\n' > "$TMP"
OUT=$(sudo -u ubuntu python3 "$ROOT/ingest.py" "$TMP" --kind apk --name "Demo APK")
echo "$OUT"
PID=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["project_id"])' <<<"$OUT")
AN="/home/ubuntu/Central/projects/$PID/canon/analysis.json"
SRC="/home/ubuntu/Central/projects/$PID/source/central-ingest-v1-demo.apk"
test -f "$AN"
test -f "$SRC"
grep -qx 'CENTRAL_INGEST_V1_DEMO' "$SRC"
python3 /home/ubuntu/Central/canon/v1/validate_canon.py "$AN"
echo INGEST_V1_LOCAL_FILE_RETEST_OK

echo "=== 4. RETEST WEB URL INGEST ==="
OUT2=$(sudo -u ubuntu python3 "$ROOT/ingest.py" "https://example.com/app" --kind web_url --name "Demo Web")
echo "$OUT2"
PID2=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["project_id"])' <<<"$OUT2")
AN2="/home/ubuntu/Central/projects/$PID2/canon/analysis.json"
test -f "$AN2"
python3 /home/ubuntu/Central/canon/v1/validate_canon.py "$AN2"
python3 - "$AN2" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8"))
assert x["source"]["kind"]=="web_url",x
print("INGEST_V1_WEB_URL_RETEST_OK")
PY

echo CENTRAL_INGEST_V1_PERMISSIONS_FIXED_READY
echo "backup=$BACKUP"
