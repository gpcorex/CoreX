#!/usr/bin/env bash
set -euo pipefail

PID="\${1:-20260923-092511-crunchyroll-20v3-112-2-20-premium-apk-ecb4b7}"
P="/home/ubuntu/Central/projects/$PID"
OUT="$P/work/diagnostics"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

echo "=== CENTRAL CRUNCHYROLL DIAGNOSTIC V1 ==="
echo "project=$PID"
test -d "$P"

python3 - "$P" "$OUT/report-$STAMP.json" <<'PY'
from pathlib import Path
import json, sys, collections

p=Path(sys.argv[1]); out=Path(sys.argv[2])

def load(rel):
    f=p/rel
    if not f.is_file(): return None
    try: return json.loads(f.read_text(encoding="utf-8",errors="replace"))
    except Exception: return None

analysis=load("canon/analysis.json") or {}
components=load("work/functional/components.json") or {}
decoded=load("work/deobfuscation/decoded-strings.json")
interesting=load("work/deobfuscation/interesting-strings.json")
routines=load("work/deobfuscation/decoder-routines.json")

pkg=(analysis.get("package") or analysis.get("package_name") or
     analysis.get("app",{}).get("package") or analysis.get("identity",{}).get("package"))

smali_roots=[]
for x in (p/"work").rglob("smali*"):
    if x.is_dir() and x.name.startswith("smali"):
        smali_roots.append(x)

prefixes=collections.Counter()
classes=[]
for root in smali_roots:
    for f in root.rglob("*.smali"):
        try:
            rel=f.relative_to(root).with_suffix("")
            parts=rel.parts
            if len(parts)>=2:
                prefixes[".".join(parts[:2])] += 1
            if len(parts)>=3:
                prefixes[".".join(parts[:3])] += 1
            classes.append("/".join(parts))
        except Exception:
            pass

def flatten_strings(obj, limit=200000):
    vals=[]
    stack=[obj]
    while stack and len(vals)<limit:
        x=stack.pop()
        if isinstance(x,str):
            vals.append(x)
        elif isinstance(x,list):
            stack.extend(x[:50000])
        elif isinstance(x,dict):
            stack.extend(list(x.values())[:50000])
    return vals

terms=["crunchy","catalog","series","season","episode","play","player","stream","manifest","dash","hls",
       "widevine","drm","license","subtitle","audio","search","login","auth","profile","watchlist","history"]
strings=flatten_strings(interesting if interesting is not None else decoded)
hits={t:[] for t in terms}
for s in strings:
    low=s.lower()
    for t in terms:
        if t in low and len(hits[t])<12:
            hits[t].append(s[:300])

raw_components=[]
if isinstance(components,dict):
    cand=components.get("components") or components.get("items") or components.get("roles") or []
    if isinstance(cand,dict):
        cand=[dict({"role":k},**(v if isinstance(v,dict) else {"value":v})) for k,v in cand.items()]
    if isinstance(cand,list):
        raw_components=cand
elif isinstance(components,list):
    raw_components=components

comp_summary=[]
for c in raw_components:
    if not isinstance(c,dict): continue
    comp_summary.append({
        "role": c.get("role") or c.get("name"),
        "score": c.get("score"),
        "confidence": c.get("confidence"),
        "member_count": len(c.get("members") or c.get("classes") or []),
        "owned_core_verified": c.get("owned_core_verified"),
        "seed_count": c.get("seed_count"),
        "status": c.get("status"),
    })

report={
    "project_id": p.name,
    "package": pkg,
    "smali_root_count": len(smali_roots),
    "class_count": len(classes),
    "top_package_prefixes": prefixes.most_common(40),
    "component_count_raw": len(comp_summary),
    "components": comp_summary,
    "interesting_string_count_sampled": len(strings),
    "semantic_hits": {k:v for k,v in hits.items() if v},
    "decoder_routines_present": routines is not None,
    "diagnosis": []
}

if not comp_summary:
    report["diagnosis"].append("FUNCTIONAL_COMPONENTIZER_EMITTED_NO_COMPONENTS")
else:
    if not any(c.get("owned_core_verified") for c in comp_summary):
        report["diagnosis"].append("COMPONENTS_FOUND_BUT_NONE_OWNERSHIP_VERIFIED")

if pkg:
    owned=sum(1 for c in classes if c.replace("/",".").startswith(pkg+".") or c.replace("/",".")==pkg)
    report["app_owned_class_count_by_manifest_package"]=owned
    if owned==0:
        report["diagnosis"].append("MANIFEST_PACKAGE_HAS_NO_DIRECT_SMALI_OWNERSHIP")

if any(k in report["semantic_hits"] for k in ("catalog","series","season","episode","player","stream","search")):
    report["diagnosis"].append("SEMANTIC_EVIDENCE_EXISTS_DESPITE_ZERO_VERIFIED_COMPONENTS")

out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print(json.dumps(report,ensure_ascii=False))
PY

echo
echo "=== SUMMARY ==="
python3 - "$OUT/report-$STAMP.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8"))
print("package=",x.get("package"))
print("smali_roots=",x.get("smali_root_count"))
print("classes=",x.get("class_count"))
print("raw_components=",x.get("component_count_raw"))
print("app_owned_class_count_by_manifest_package=",x.get("app_owned_class_count_by_manifest_package"))
print("diagnosis="," | ".join(x.get("diagnosis") or []))
print("top_prefixes:")
for k,v in (x.get("top_package_prefixes") or [])[:15]:
    print(" ",v,k)
print("semantic_hits:")
for k,v in (x.get("semantic_hits") or {}).items():
    print(" ",k,":",len(v))
PY

echo
echo CENTRAL_CRUNCHYROLL_DIAGNOSTIC_V1_READY
echo "report=$OUT/report-$STAMP.json"
