#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/master_pipeline_v1
MASTER="$ROOT/run_central_extraction.py"
SERVER=/home/ubuntu/Central/auditor_ui_v1/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/master-pipeline-v1-$STAMP
mkdir -p "$ROOT" "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py.before"

echo "=== 1. INSTALL CENTRAL MASTER EXTRACTION PIPELINE V1 ==="
cat >"$MASTER" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, subprocess, sys
from pathlib import Path

BASE=Path("/home/ubuntu/Central/pipeline_v1/run_android_pipeline.py")
PROJECTS=Path("/home/ubuntu/Central/projects")
BUILDER=Path("/home/ubuntu/Central/component_package_builder_v1/build_component_package.py")
CONTRACT=Path("/home/ubuntu/Central/contract_extractor_v1/extract_component_contract.py")
REFINER=Path("/home/ubuntu/Central/callgraph_refiner_v1/refine_component_contract.py")
SLICER=Path("/home/ubuntu/Central/behavior_slicer_v1/slice_component_behavior.py")
SYNTH=Path("/home/ubuntu/Central/interface_synthesizer_v1/synthesize_interface.py")
SCAFFOLD=Path("/home/ubuntu/Central/clean_adapter_scaffold_v1/build_clean_adapter_scaffold.py")

TOTAL_STAGES=16
STAGE_NAMES={
  11:"Selección de componentes confirmados",
  12:"Bundles y contratos",
  13:"Call graph refinado",
  14:"Behavior slicing",
  15:"Interfaz limpia",
  16:"Informe final"
}

def emit_stage(n,detail=None):
    print(json.dumps({
      "event":"stage","stage":n,"stage_total":TOTAL_STAGES,
      "stage_name":STAGE_NAMES[n],"detail":detail
    },ensure_ascii=False),flush=True)

def parse_json_line(line):
    t=line.strip()
    if not (t.startswith("{") and t.endswith("}")):
        return None
    try:
        x=json.loads(t)
        return x if isinstance(x,dict) else None
    except Exception:
        return None

def stream_base(cmd):
    cp=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
    last_result=None
    assert cp.stdout is not None
    for raw in cp.stdout:
        line=raw.rstrip(chr(10))
        evt=parse_json_line(line)
        if evt and evt.get("event")=="stage":
            evt["stage_total"]=TOTAL_STAGES
            print(json.dumps(evt,ensure_ascii=False),flush=True)
        else:
            print(line,flush=True)
        if evt and evt.get("event") not in {"stage","deobf_progress","resolver_progress"}:
            last_result=evt
    rc=cp.wait()
    return rc,last_result

def run_json(cmd,label):
    cp=subprocess.run(cmd,text=True,capture_output=True)
    if cp.stdout:
        for line in cp.stdout.splitlines():
            print(line,flush=True)
    if cp.returncode!=0:
        if cp.stderr: print(cp.stderr,flush=True)
        raise RuntimeError(f"{label}_FAILED rc={cp.returncode}")
    for line in reversed(cp.stdout.splitlines()):
        obj=parse_json_line(line)
        if obj and obj.get("event") not in {"stage","deobf_progress","resolver_progress"}:
            return obj
    raise RuntimeError(f"{label}_NO_JSON_RESULT")

def choose_profile(source:Path|None):
    if not source or not source.is_file():
        return "existing"
    size=source.stat().st_size
    return "heavy" if size >= 80*1024*1024 else "standard"

def main():
    ap=argparse.ArgumentParser(description="Central master APK/XAPK extraction pipeline")
    ap.add_argument("source",nargs="?")
    ap.add_argument("--kind",choices=["apk","xapk"],default=None)
    ap.add_argument("--name",default=None)
    ap.add_argument("--project-id",default=None,help="Post-process an existing project without rerunning extraction")
    args=ap.parse_args()

    source=Path(args.source).expanduser().resolve() if args.source else None
    profile=choose_profile(source)
    project_id=args.project_id
    base_result=None

    required=[BUILDER,CONTRACT,REFINER,SLICER,SYNTH,SCAFFOLD]
    missing=[str(p) for p in required if not p.is_file()]
    if missing:
        print(json.dumps({"ok":False,"error":"MASTER_PIPELINE_DEPENDENCY_MISSING","missing":missing},ensure_ascii=False),flush=True)
        raise SystemExit(2)

    if not project_id:
        if not source or not source.is_file():
            print(json.dumps({"ok":False,"error":"SOURCE_FILE_NOT_FOUND"},ensure_ascii=False),flush=True)
            raise SystemExit(2)
        cmd=["python3",str(BASE),str(source)]
        if args.kind: cmd += ["--kind",args.kind]
        if args.name: cmd += ["--name",args.name]
        rc,base_result=stream_base(cmd)
        if rc!=0 or not isinstance(base_result,dict) or not base_result.get("ok"):
            print(json.dumps({"ok":False,"error":"BASE_PIPELINE_FAILED","returncode":rc,"base_result":base_result},ensure_ascii=False),flush=True)
            raise SystemExit(rc or 2)
        project_id=base_result.get("project_id")

    project=PROJECTS/str(project_id)
    deps=project/"work"/"dependencies"/"summary.json"
    if not deps.is_file():
        print(json.dumps({"ok":False,"error":"DEPENDENCY_SUMMARY_NOT_FOUND","project_id":project_id},ensure_ascii=False),flush=True)
        raise SystemExit(2)

    emit_stage(11,f"profile={profile}")
    summary=json.load(open(deps,encoding="utf-8"))
    verified=[
      c for c in (summary.get("components") or [])
      if c.get("owned_core_verified") and int(c.get("seed_count") or 0)>0
    ]
    verified.sort(key=lambda c:(int(c.get("seed_count") or 0),c.get("role","")))

    # Heavy APKs get bounded deep processing; all confirmed components remain listed.
    deep_limit=4 if profile=="heavy" else 8
    selected=verified[:deep_limit]

    emit_stage(12,f"{len(selected)}/{len(verified)} componentes profundos")
    component_results=[]
    for idx,c in enumerate(selected,1):
        role=c["role"]
        print(json.dumps({"event":"master_progress","phase":"bundle_contract","current":idx,"total":len(selected),"role":role},ensure_ascii=False),flush=True)
        b=run_json(["python3",str(BUILDER),str(project_id),role],f"bundle_{role}")
        ct=run_json(["python3",str(CONTRACT),str(project_id),role],f"contract_{role}")
        component_results.append({
          "role":role,
          "bundle_ok":bool(b.get("ok")),
          "contract_ok":bool(ct.get("ok")),
          "contract_skipped":bool(ct.get("skipped",False))
        })

    emit_stage(13,f"{len(selected)} componentes")
    refined=[]
    for idx,c in enumerate(selected,1):
        role=c["role"]
        print(json.dumps({"event":"master_progress","phase":"callgraph","current":idx,"total":len(selected),"role":role},ensure_ascii=False),flush=True)
        try:
            r=run_json(["python3",str(REFINER),str(project_id),role],f"refiner_{role}")
            refined.append({"role":role,"ok":bool(r.get("ok")),"skipped":bool(r.get("skipped",False))})
        except Exception as e:
            refined.append({"role":role,"ok":False,"error":str(e)})

    detail_supported=any(c.get("role")=="detail" for c in selected)

    emit_stage(14,"detail_metadata" if detail_supported else "sin slicers especializados aplicables")
    detail_slice=None
    if detail_supported:
        detail_slice=run_json(["python3",str(SLICER),str(project_id),"detail","--slice","detail_metadata"],"detail_behavior_slice")

    emit_stage(15,"detail_metadata" if detail_supported else "sin interfaz especializada aplicable")
    detail_interface=None
    detail_scaffold=None
    if detail_supported:
        detail_interface=run_json(["python3",str(SYNTH),str(project_id),"detail","--slice","detail_metadata"],"detail_interface")
        detail_scaffold=run_json(["python3",str(SCAFFOLD),str(project_id),"detail"],"detail_scaffold")

    emit_stage(16,"Guardando informe maestro")
    out=project/"work"/"master-pipeline"
    out.mkdir(parents=True,exist_ok=True)
    report={
      "schema_version":"central.master-extraction.v1",
      "ok":True,
      "project_id":project_id,
      "profile":profile,
      "source_size":source.stat().st_size if source and source.is_file() else None,
      "verified_component_count":len(verified),
      "verified_components":[
        {
          "role":c.get("role"),"name":c.get("name"),"seed_count":c.get("seed_count"),
          "minimal_internal_count":c.get("minimal_internal_count"),
          "confidence":c.get("confidence"),"reuse_assessment":c.get("reuse_assessment")
        } for c in verified
      ],
      "deep_processed_count":len(selected),
      "deep_processed_roles":[c.get("role") for c in selected],
      "component_results":component_results,
      "refined_results":refined,
      "detail_specialization":{
        "applicable":detail_supported,
        "slice_ok":bool(detail_slice and detail_slice.get("ok")),
        "interface_ok":bool(detail_interface and detail_interface.get("ok")),
        "scaffold_ok":bool(detail_scaffold and detail_scaffold.get("ok")),
      },
      "policy":{
        "heavy_threshold_bytes":80*1024*1024,
        "heavy_deep_component_limit":4,
        "standard_deep_component_limit":8,
        "note":"Heavy profile bounds post-analysis depth. Base structural/deobfuscation pipeline remains evidence-complete."
      }
    }
    rp=out/"report.json"
    rp.write_text(json.dumps(report,ensure_ascii=False,indent=2)+chr(10),encoding="utf-8")

    print(json.dumps({
      "ok":True,
      "project_id":project_id,
      "profile":profile,
      "verified_component_count":len(verified),
      "deep_processed_count":len(selected),
      "master_report":str(rp),
      "master":report
    },ensure_ascii=False),flush=True)

if __name__=="__main__":
    main()
PY

chmod 755 "$MASTER"
python3 -m py_compile "$MASTER"
echo CENTRAL_MASTER_PIPELINE_V1_SOURCE_OK

echo "=== 2. CONNECT AUDITOR TO MASTER PIPELINE ==="
python3 - "$SERVER" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")
old='PIPE=Path("/home/ubuntu/Central/pipeline_v1/run_android_pipeline.py")'
new='PIPE=Path("/home/ubuntu/Central/master_pipeline_v1/run_central_extraction.py")'
if old in s:
    s=s.replace(old,new,1)
elif new not in s:
    raise SystemExit("AUDITOR_PIPE_ANCHOR_NOT_FOUND")
p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$SERVER"
grep -q 'master_pipeline_v1/run_central_extraction.py' "$SERVER"
echo CENTRAL_MASTER_PIPELINE_V1_AUDITOR_CONNECTED_OK

echo "=== 3. POST-PROCESS EXISTING F-DROID PROJECT AS MASTER SELFTEST ==="
LATEST=$(python3 - <<'PY'
import json
rows=json.load(open("/home/ubuntu/Central/auditor_ui_v1/data/runs.json",encoding="utf-8"))
for r in rows:
    if r.get("status")=="COMPLETED" and r.get("project_id"):
        print(r["project_id"]);break
PY
)
test -n "$LATEST"
echo "project=$LATEST"
TMP=/tmp/master-pipeline-v1-$STAMP.log
sudo -u ubuntu python3 "$MASTER" --project-id "$LATEST" 2>&1 | tee "$TMP"
LAST=$(tail -n1 "$TMP")
python3 - "$LAST" <<'PY'
import json,sys,os
x=json.loads(sys.argv[1])
assert x["ok"] is True
assert x["verified_component_count"]>=1
assert os.path.isfile(x["master_report"])
print("CENTRAL_MASTER_PIPELINE_V1_EXISTING_PROJECT_OK")
print("profile="+x["profile"])
print("verified_component_count="+str(x["verified_component_count"]))
print("deep_processed_count="+str(x["deep_processed_count"]))
print("master_report="+x["master_report"])
PY

echo "=== 4. RESTART AUDITOR + PUBLIC CHECK ==="
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8792/api/health >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
grep -q 'master_pipeline_v1/run_central_extraction.py' "$SERVER"
echo CENTRAL_MASTER_PIPELINE_V1_PUBLIC_OK

echo CENTRAL_MASTER_EXTRACTION_PIPELINE_V1_READY
echo "auditor_pipeline=$MASTER"
echo "project_tested=$LATEST"
echo "backup=$BACKUP"
