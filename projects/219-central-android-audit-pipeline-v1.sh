#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/pipeline_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/android-pipeline-v1-$STAMP
mkdir -p "$ROOT" "$BACKUP"

echo "=== 1. INSTALL UNIFIED ANDROID AUDIT PIPELINE ==="
cat >"$ROOT/run_android_pipeline.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, subprocess, sys
from pathlib import Path

INGEST=Path("/home/ubuntu/Central/ingest_v1/ingest.py")
AUDITOR=Path("/home/ubuntu/Central/auditor_v1/audit_android.py")
DEOBF=Path("/home/ubuntu/Central/deobfuscator_v1/deobfuscate_android.py")
PROJECTS=Path("/home/ubuntu/Central/projects")

def run(cmd):
    cp=subprocess.run(cmd,text=True,capture_output=True)
    return cp.returncode,cp.stdout.strip(),cp.stderr.strip()

def parse_last_json(text):
    for line in reversed(text.splitlines()):
        line=line.strip()
        if line.startswith("{") and line.endswith("}"):
            return json.loads(line)
    raise ValueError("no json object found")

def main():
    ap=argparse.ArgumentParser(description="Central Android audit pipeline v1")
    ap.add_argument("source",help="APK or XAPK path")
    ap.add_argument("--kind",choices=["apk","xapk"],default=None)
    ap.add_argument("--name",default=None)
    a=ap.parse_args()

    src=Path(a.source).expanduser().resolve()
    if not src.is_file():
        raise SystemExit("SOURCE_FILE_NOT_FOUND:"+str(src))
    kind=a.kind or ("xapk" if src.suffix.lower()==".xapk" else "apk")

    cmd=["python3",str(INGEST),str(src),"--kind",kind]
    if a.name:
        cmd += ["--name",a.name]
    rc,out,err=run(cmd)
    if rc!=0:
        print(json.dumps({"ok":False,"stage":"ingest","stdout":out,"stderr":err},ensure_ascii=False))
        raise SystemExit(rc)
    ing=parse_last_json(out)
    pid=ing["project_id"]

    rc,out,err=run(["python3",str(AUDITOR),pid])
    if rc!=0:
        print(json.dumps({"ok":False,"stage":"audit","project_id":pid,"stdout":out,"stderr":err},ensure_ascii=False))
        raise SystemExit(rc)
    audit=parse_last_json(out)

    deobf=None
    deobf_status="SKIPPED_NO_DECODED_TREE"
    decoded=PROJECTS/pid/"work"/"android-audit"/"decoded"
    if audit.get("apktool_ok") and decoded.is_dir():
        rc,out,err=run(["python3",str(DEOBF),pid])
        if rc==0:
            deobf=parse_last_json(out)
            deobf_status="OK"
        else:
            deobf_status="FAILED"
            deobf={"stdout":out,"stderr":err,"returncode":rc}

    result={
        "ok": True,
        "project_id": pid,
        "kind": kind,
        "audit": audit,
        "deobfuscation_status": deobf_status,
        "deobfuscation": deobf,
        "analysis_path": str(PROJECTS/pid/"canon"/"analysis.json")
    }
    print(json.dumps(result,ensure_ascii=False))

if __name__=="__main__":
    main()
PY

chmod 755 "$ROOT/run_android_pipeline.py"
python3 -m py_compile "$ROOT/run_android_pipeline.py"
echo ANDROID_PIPELINE_V1_SOURCE_OK

echo "=== 2. INSTALL README ==="
cat >"$ROOT/README.md" <<'EOF'
# Central Android Pipeline V1

Un solo comando:
1. ingesta APK/XAPK;
2. auditoría estructural;
3. si apktool logró decodificar la APK real, desofuscación automática;
4. actualización del modelo canónico.

Uso:

python3 /home/ubuntu/Central/pipeline_v1/run_android_pipeline.py /ruta/app.apk

El pipeline no considera un fallo que una fixture sintética no pueda ser decodificada por
apktool. En una APK Android real, apktool_ok=true habilita automáticamente la etapa de
desofuscación.
EOF

echo "=== 3. VERIFY GRACEFUL FALLBACK WITH CURRENT SYNTHETIC FIXTURE ==="
test -s /tmp/central-auditor-v1.apk
OUT=$(sudo -u ubuntu python3 "$ROOT/run_android_pipeline.py" /tmp/central-auditor-v1.apk --kind apk --name "Pipeline Fixture")
echo "$OUT"

python3 - <<'PY' <<<"$OUT"
PY

python3 - "$OUT" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x["ok"] is True,x
assert x["audit"]["dex_count"]>=1,x
assert x["audit"]["native_libs"]>=1,x
assert x["deobfuscation_status"] in {"SKIPPED_NO_DECODED_TREE","OK"},x
print("ANDROID_PIPELINE_V1_FALLBACK_OK")
PY

echo "=== 4. VERIFY COMPONENTS EXIST ==="
test -x /home/ubuntu/Central/ingest_v1/ingest.py
test -x /home/ubuntu/Central/auditor_v1/audit_android.py
test -x /home/ubuntu/Central/deobfuscator_v1/deobfuscate_android.py
echo ANDROID_PIPELINE_V1_COMPONENTS_OK

echo CENTRAL_ANDROID_PIPELINE_V1_READY
echo "runner=$ROOT/run_android_pipeline.py"
echo "backup=$BACKUP"
