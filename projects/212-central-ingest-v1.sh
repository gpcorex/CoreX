#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/ingest_v1
PROJECTS=/home/ubuntu/Central/projects
CANON=/home/ubuntu/Central/canon/v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/ingest-v1-$STAMP

mkdir -p "$ROOT" "$PROJECTS" "$BACKUP"

echo "=== 1. INSTALL INGEST V1 ==="
cat >"$ROOT/ingest.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, hashlib, json, os, shutil, sys, time, urllib.parse, uuid
from pathlib import Path

PROJECTS=Path("/home/ubuntu/Central/projects")
CANON=Path("/home/ubuntu/Central/canon/v1")
VALIDATOR=CANON/"validate_canon.py"

KINDS={
    "apk","xapk","installed_android_app","web_url","pwa",
    "source_project","desktop_package","other"
}

def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())

def sha256_file(path:Path)->str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda:f.read(1024*1024),b""):
            h.update(chunk)
    return h.hexdigest()

def infer_kind(origin:str)->str:
    low=origin.lower()
    if low.startswith("http://") or low.startswith("https://"):
        return "web_url"
    p=Path(origin)
    if p.is_dir():
        return "source_project"
    if low.endswith(".apk"):
        return "apk"
    if low.endswith(".xapk"):
        return "xapk"
    if low.endswith((".exe",".msi",".deb",".rpm",".appimage",".dmg",".pkg")):
        return "desktop_package"
    return "other"

def slug(s:str)->str:
    out=[]
    for ch in s.lower():
        out.append(ch if ch.isalnum() else "-")
    x="".join(out)
    while "--" in x:x=x.replace("--","-")
    return x.strip("-")[:48] or "source"

def build_analysis(project_id:str,kind:str,origin:str,artifact_name:str|None,sha:str|None,name:str):
    return {
      "schema_version":"central.analysis.v1",
      "analysis_id":"AN-"+project_id,
      "created_at":now_iso(),
      "source":{
        "kind":kind,
        "origin":origin,
        "artifact_name":artifact_name,
        "package_name":None,
        "version":None,
        "hash_sha256":sha,
        "captured_at":now_iso()
      },
      "identity":{
        "name":name,
        "platform":"unknown",
        "description":"Ingestado; análisis técnico pendiente.",
        "entrypoints":[]
      },
      "interfaces":[],
      "behaviors":[],
      "data":{"models":[],"local_storage":[],"apis":[],"formats":[]},
      "media":{"players":[],"streams":[],"codecs":[],"drm":[],"subtitles":[]},
      "security":{"authentication":[],"permissions":[],"certificates":[],"restrictions":[]},
      "components":[],
      "dependencies":[],
      "evidence":[],
      "notes":["INGEST_V1_OK","Pendiente de análisis por adaptador específico."]
    }

def main():
    ap=argparse.ArgumentParser(description="Central generic ingestion v1")
    ap.add_argument("origin")
    ap.add_argument("--kind",default="auto")
    ap.add_argument("--name",default=None)
    a=ap.parse_args()

    kind=infer_kind(a.origin) if a.kind=="auto" else a.kind
    if kind not in KINDS:
        raise SystemExit("UNSUPPORTED_SOURCE_KIND:"+kind)

    is_url=a.origin.startswith(("http://","https://"))
    source_path=None if is_url else Path(a.origin).expanduser().resolve()

    if kind in {"apk","xapk","desktop_package","other"}:
        if source_path is None or not source_path.is_file():
            raise SystemExit("SOURCE_FILE_NOT_FOUND:"+a.origin)
    if kind=="source_project":
        if source_path is None or not source_path.is_dir():
            raise SystemExit("SOURCE_DIRECTORY_NOT_FOUND:"+a.origin)

    base_name=(
        Path(urllib.parse.urlparse(a.origin).path).name if is_url
        else source_path.name if source_path else a.origin
    ) or "source"
    display=a.name or base_name

    project_id=time.strftime("%Y%m%d-%H%M%S",time.gmtime())+"-"+slug(display)+"-"+uuid.uuid4().hex[:6]
    root=PROJECTS/project_id
    src=root/"source"
    canon=root/"canon"
    work=root/"work"
    for d in (src,canon,work): d.mkdir(parents=True,exist_ok=True)

    copied=None
    sha=None
    if source_path and source_path.is_file():
        copied=src/source_path.name
        shutil.copy2(source_path,copied)
        sha=sha256_file(copied)
    elif source_path and source_path.is_dir():
        # V1 records a project directory by reference; deep snapshot is a later adapter concern.
        pass

    analysis=build_analysis(
        project_id,kind,a.origin,
        copied.name if copied else (base_name if source_path and source_path.is_file() else None),
        sha,display
    )
    analysis_path=canon/"analysis.json"
    analysis_path.write_text(json.dumps(analysis,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    manifest={
      "project_id":project_id,
      "created_at":now_iso(),
      "kind":kind,
      "origin":a.origin,
      "stored_source":str(copied) if copied else None,
      "analysis":str(analysis_path),
      "status":"INGESTED"
    }
    (root/"project.json").write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    print(json.dumps({
      "ok":True,
      "project_id":project_id,
      "kind":kind,
      "project_root":str(root),
      "analysis_path":str(analysis_path),
      "stored_source":str(copied) if copied else None
    },ensure_ascii=False))

if __name__=="__main__":
    main()
PY

chmod 755 "$ROOT/ingest.py"
python3 -m py_compile "$ROOT/ingest.py"
echo INGEST_V1_SOURCE_OK

echo "=== 2. INSTALL INGEST CONTRACT ==="
cat >"$ROOT/README.md" <<'EOF'
# Central Ingest V1

Normaliza distintas entradas hacia un proyecto Central.

## Entradas

- APK
- XAPK
- URL web
- PWA
- proyecto con código
- aplicación Android instalada (registro/origen; extracción específica vendrá después)
- paquete de escritorio
- otros archivos

## Salida por proyecto

/home/ubuntu/Central/projects/<project_id>/
- project.json
- source/
- canon/analysis.json
- work/

La ingesta no analiza todavía la aplicación. Sólo registra/copia la fuente cuando corresponde
y crea un analysis.json válido como punto de partida para los adaptadores de auditoría.
EOF

echo "=== 3. LOCAL FILE INGEST TEST ==="
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
python3 "$CANON/validate_canon.py" "$AN"
echo INGEST_V1_LOCAL_FILE_OK

echo "=== 4. WEB URL INGEST TEST ==="
OUT2=$(sudo -u ubuntu python3 "$ROOT/ingest.py" "https://example.com/app" --kind web_url --name "Demo Web")
echo "$OUT2"
PID2=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["project_id"])' <<<"$OUT2")
AN2="/home/ubuntu/Central/projects/$PID2/canon/analysis.json"
test -f "$AN2"
python3 "$CANON/validate_canon.py" "$AN2"
python3 - "$AN2" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8"))
assert x["source"]["kind"]=="web_url",x
assert x["source"]["origin"]=="https://example.com/app",x
print("INGEST_V1_WEB_URL_OK")
PY

echo "=== 5. VERIFY PROJECT CONTRACT ==="
python3 - "$PID" <<'PY'
import json,sys
from pathlib import Path
root=Path("/home/ubuntu/Central/projects")/sys.argv[1]
m=json.load(open(root/"project.json",encoding="utf-8"))
assert m["status"]=="INGESTED",m
assert (root/"source").is_dir()
assert (root/"canon"/"analysis.json").is_file()
assert (root/"work").is_dir()
print("INGEST_V1_PROJECT_CONTRACT_OK")
PY

echo CENTRAL_INGEST_V1_READY
echo "root=$ROOT"
echo "projects=$PROJECTS"
echo "backup=$BACKUP"
