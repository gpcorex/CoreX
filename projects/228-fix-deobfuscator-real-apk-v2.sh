#!/usr/bin/env bash
set -euo pipefail

DEOBF=/home/ubuntu/Central/deobfuscator_v1/deobfuscate_android.py
PIPE=/home/ubuntu/Central/pipeline_v1/run_android_pipeline.py
UI=/home/ubuntu/Central/auditor_ui_v1/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/auditor-deobf-fix-v2-$STAMP
mkdir -p "$BACKUP"
cp -a "$DEOBF" "$BACKUP/deobfuscate_android.py.before"
cp -a "$PIPE" "$BACKUP/run_android_pipeline.py.before"
cp -a "$UI" "$BACKUP/server.py.before"

echo "=== 1. FIX SURROGATE-SAFE STRING HANDLING + PROGRESS ==="
python3 - "$DEOBF" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

if "def clean_text(" not in s:
    anchor='''def text_quality(s:str)->float:
'''
    helper='''def clean_text(s):
    if not isinstance(s,str):
        s=str(s)
    # Remove lone surrogate code points that cannot be encoded as UTF-8.
    return s.encode("utf-8","replace").decode("utf-8")

def emit_progress(phase,current,total=None,detail=None):
    import json
    print(json.dumps({
        "event":"deobf_progress",
        "phase":phase,
        "current":current,
        "total":total,
        "detail":detail
    },ensure_ascii=False),flush=True)

'''
    if anchor not in s:
        raise SystemExit("CLEAN_TEXT_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,helper+anchor,1)

# Sanitize recovered strings before storing.
old='''def unique_add(out, seen, original, decoded, method, source, depth):
    decoded=decoded.strip("\\x00")
'''
new='''def unique_add(out, seen, original, decoded, method, source, depth):
    original=clean_text(original)
    decoded=clean_text(decoded).strip("\\x00")
    source=clean_text(source)
'''
if old not in s:
    raise SystemExit("UNIQUE_ADD_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

# Sanitize extracted smali strings too.
s=s.replace(
'''                out.append(bytes(m.group(1),"utf-8").decode("unicode_escape",errors="ignore"))
''',
'''                out.append(clean_text(bytes(m.group(1),"utf-8").decode("unicode_escape",errors="ignore")))
''',1)

# Add file-scan progress.
old='''    files=[]
    for p in decoded.rglob("*"):
        if p.is_file() and p.stat().st_size<=5*1024*1024:
            files.append(p)
            if len(files)>=a.max_files:break

    routines=scan_decoder_routines(files)
'''
new='''    files=[]
    for p in decoded.rglob("*"):
        if p.is_file() and p.stat().st_size<=5*1024*1024:
            files.append(p)
            if len(files)>=a.max_files:break

    emit_progress("files_discovered",len(files),len(files),"Archivos candidatos listos")
    routines=scan_decoder_routines(files)
    emit_progress("decoder_routines",len(routines),None,"Rutinas sospechosas detectadas")
'''
if old not in s:
    raise SystemExit("FILES_PROGRESS_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

# Add extraction progress.
old='''    recovered=[];seen=set();inputs=0
    queue=[]
    for p in files:
        rel=str(p.relative_to(decoded))
        for s in extract_strings(p):
            inputs+=1
            queue.append((s,s,rel,0))
'''
new='''    recovered=[];seen=set();inputs=0
    queue=[]
    total_files=len(files)
    for idx,p in enumerate(files,1):
        rel=str(p.relative_to(decoded))
        for sv in extract_strings(p):
            inputs+=1
            queue.append((sv,sv,rel,0))
        if idx==1 or idx%250==0 or idx==total_files:
            emit_progress("extract_strings",idx,total_files,f"strings={inputs}")
'''
if old not in s:
    raise SystemExit("EXTRACTION_PROGRESS_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

# Add decode progress.
old='''    qi=0
    while qi<len(queue):
        original,current,source,depth=queue[qi];qi+=1
        if depth>=a.max_depth:continue
        for method,decoded_s in decode_candidates(current):
'''
new='''    qi=0
    last_report=0
    while qi<len(queue):
        original,current,source,depth=queue[qi];qi+=1
        if qi==1 or qi-last_report>=1000 or qi==len(queue):
            emit_progress("decode_strings",qi,len(queue),f"recovered={len(recovered)}")
            last_report=qi
        if depth>=a.max_depth:continue
        for method,decoded_s in decode_candidates(current):
'''
if old not in s:
    raise SystemExit("DECODE_PROGRESS_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

# Sanitize before JSON serialization as final guard.
old='''    recovered.sort(key=lambda x:(not x["interesting"],x["source"],x["method"]))
    work=root/"work"/"deobfuscation"
'''
new='''    recovered.sort(key=lambda x:(not x["interesting"],x["source"],x["method"]))
    for row in recovered:
        for k,v in list(row.items()):
            if isinstance(v,str):
                row[k]=clean_text(v)
    for row in routines:
        for k,v in list(row.items()):
            if isinstance(v,str):
                row[k]=clean_text(v)
            elif isinstance(v,list):
                row[k]=[clean_text(x) if isinstance(x,str) else x for x in v]
    work=root/"work"/"deobfuscation"
'''
if old not in s:
    raise SystemExit("FINAL_SANITIZE_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$DEOBF"
echo DEOBFUSCATOR_SURROGATE_FIX_OK

echo "=== 2. FIX PIPELINE: DEOBF FAILURE MUST FAIL RUN + FORWARD PROGRESS ==="
python3 - "$PIPE" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

# Make subprocess output streamable.
old='''def run(cmd):
    cp=subprocess.run(cmd,text=True,capture_output=True)
    return cp.returncode,cp.stdout.strip(),cp.stderr.strip()
'''
new='''def run(cmd):
    cp=subprocess.run(cmd,text=True,capture_output=True)
    return cp.returncode,cp.stdout.strip(),cp.stderr.strip()

def run_stream(cmd):
    cp=subprocess.Popen(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,bufsize=1)
    lines=[]
    assert cp.stdout is not None
    for line in cp.stdout:
        print(line.rstrip("\n"),flush=True)
        lines.append(line)
    rc=cp.wait()
    return rc,"".join(lines).strip(),""
'''
if old in s:
    s=s.replace(old,new,1)

old='''        rc,out,err=run(["python3",str(DEOBF),pid])
        if rc==0:
            deobf=parse_last_json(out)
            deobf_status="OK"
        else:
            deobf_status="FAILED"
            deobf={"stdout":out,"stderr":err,"returncode":rc}
'''
new='''        rc,out,err=run_stream(["python3",str(DEOBF),pid])
        if rc==0:
            deobf=parse_last_json(out)
            deobf_status="OK"
        else:
            deobf_status="FAILED"
            deobf={"stdout":out,"stderr":err,"returncode":rc}
'''
if old not in s:
    raise SystemExit("PIPE_DEOBF_RUN_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

old='''    result={
        "ok": True,
'''
new='''    overall_ok = deobf_status != "FAILED"
    result={
        "ok": overall_ok,
'''
if old not in s:
    raise SystemExit("PIPE_RESULT_OK_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

# Ensure non-zero exit when deobfuscation failed.
old='''    print(json.dumps(result,ensure_ascii=False))

if __name__=="__main__":
'''
new='''    print(json.dumps(result,ensure_ascii=False))
    if not overall_ok:
        raise SystemExit(2)

if __name__=="__main__":
'''
if old not in s:
    raise SystemExit("PIPE_EXIT_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$PIPE"
echo ANDROID_PIPELINE_DEOBF_FAILURE_PROPAGATION_OK

echo "=== 3. PATCH UI TO DISPLAY DEOBF PROGRESS EVENTS ==="
python3 - "$UI" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

old='''                        if evt.get("event")=="stage":
                            update_run(
                                rid,
                                stage=evt.get("stage"),
                                stage_total=evt.get("stage_total"),
                                stage_name=evt.get("stage_name"),
                                stage_detail=evt.get("detail")
                            )
                        else:
                            last_json=evt
'''
if old in s:
    new='''                        if evt.get("event")=="stage":
                            update_run(
                                rid,
                                stage=evt.get("stage"),
                                stage_total=evt.get("stage_total"),
                                stage_name=evt.get("stage_name"),
                                stage_detail=evt.get("detail")
                            )
                        elif evt.get("event")=="deobf_progress":
                            cur=evt.get("current")
                            total=evt.get("total")
                            phase=evt.get("phase")
                            detail=evt.get("detail")
                            txt=(f"{cur}/{total}" if total else str(cur))
                            if detail:
                                txt += " · "+str(detail)
                            update_run(rid,stage=8,stage_total=10,stage_name="Desofuscación automática",stage_detail=f"{phase}: {txt}")
                        else:
                            last_json=evt
'''
    s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$UI"
systemctl restart central-auditor-ui.service
echo AUDITOR_UI_DEOBF_PROGRESS_OK

echo "=== 4. REGRESSION TEST FOR SURROGATES ==="
TMP=/home/ubuntu/Central/projects/deobfuscator-surrogate-selftest
rm -rf "$TMP"
mkdir -p "$TMP/canon" "$TMP/work/android-audit/decoded/smali/demo"
cat >"$TMP/canon/analysis.json" <<'JSON'
{
  "schema_version":"central.analysis.v1",
  "analysis_id":"AN-DEOBF-SURROGATE",
  "created_at":"2026-09-22T00:00:00Z",
  "source":{"kind":"apk","origin":"selftest.apk","artifact_name":"selftest.apk","package_name":"demo","version":"1","hash_sha256":null,"captured_at":null},
  "identity":{"name":"Surrogate selftest","platform":"android","description":null,"entrypoints":[]},
  "interfaces":[],"behaviors":[],
  "data":{"models":[],"local_storage":[],"apis":[],"formats":[]},
  "media":{"players":[],"streams":[],"codecs":[],"drm":[],"subtitles":[]},
  "security":{"authentication":[],"permissions":[],"certificates":[],"restrictions":[]},
  "components":[],"dependencies":[],"evidence":[],"notes":[]
}
JSON
cat >"$TMP/work/android-audit/decoded/smali/demo/Test.smali" <<'SMALI'
.class public Ldemo/Test;
.super Ljava/lang/Object;
.method public static x()V
    .locals 1
    const-string v0, "\ud800https://api.example.test/player"
    return-void
.end method
SMALI
chown -R ubuntu:ubuntu "$TMP"
OUT=$(sudo -u ubuntu python3 "$DEOBF" deobfuscator-surrogate-selftest)
echo "$OUT"
test -s "$TMP/work/deobfuscation/decoded-strings.json"
python3 - <<'PY'
import json
p="/home/ubuntu/Central/projects/deobfuscator-surrogate-selftest/work/deobfuscation/decoded-strings.json"
json.load(open(p,encoding="utf-8"))
print("DEOBFUSCATOR_SURROGATE_JSON_RETEST_OK")
PY

echo "=== 5. VERIFY PUBLIC UI ==="
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo AUDITOR_PUBLIC_HEALTH_OK

echo CENTRAL_AUDITOR_DEOBF_FIX_V2_READY
echo "backup=$BACKUP"
