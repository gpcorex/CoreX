#!/usr/bin/env bash
set -euo pipefail

PID="${1:-20260923-092511-crunchyroll-20v3-112-2-20-premium-apk-ecb4b7}"
P="/home/ubuntu/Central/projects/$PID"
OUT="$P/work/diagnostics"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

echo "=== CENTRAL CRUNCHYROLL IDENTITY DIAGNOSTIC V3 ==="
echo "project=$PID"
test -d "$P"

python3 - "$P" "$OUT/identity-$STAMP.json" <<'PY'
from pathlib import Path
import json,sys,re,collections,subprocess,shlex

p=Path(sys.argv[1]); out=Path(sys.argv[2])

def jload(f):
    try: return json.loads(Path(f).read_text(encoding="utf-8",errors="replace"))
    except Exception: return None

project=jload(p/"project.json") or {}
analysis=jload(p/"canon/analysis.json") or {}

# Locate original source file.
candidates=[]
for key in ("source","source_path","input","input_path","file","path"):
    v=project.get(key)
    if isinstance(v,str): candidates.append(Path(v))
for f in (p/"source").rglob("*"):
    if f.is_file() and f.suffix.lower() in (".apk",".xapk"):
        candidates.append(f)
source=next((x for x in candidates if x.is_file()),None)

aapt_package=None
aapt_app_label=None
aapt_version=None
aapt_raw=None
if source and source.suffix.lower()==".apk":
    try:
        cp=subprocess.run(["aapt","dump","badging",str(source)],capture_output=True,text=True,timeout=90)
        aapt_raw=cp.stdout
        m=re.search(r"package: name='([^']+)' versionCode='([^']*)' versionName='([^']*)'",cp.stdout)
        if m:
            aapt_package=m.group(1); aapt_version=m.group(3)
        m=re.search(r"application-label:'([^']*)'",cp.stdout)
        if m: aapt_app_label=m.group(1)
    except Exception:
        pass

# Locate decoded AndroidManifest.xml and extract package/app class hints.
manifest_files=list((p/"work").rglob("AndroidManifest.xml"))
manifest_packages=[]
application_names=[]
activities=[]
for mf in manifest_files:
    try:
        txt=mf.read_text(encoding="utf-8",errors="replace")
    except Exception:
        continue
    mm=re.search(r'<manifest[^>]*\bpackage="([^"]+)"',txt)
    if mm: manifest_packages.append(mm.group(1))
    am=re.search(r'<application[^>]*android:name="([^"]+)"',txt)
    if am: application_names.append(am.group(1))
    for x in re.findall(r'<activity[^>]*android:name="([^"]+)"',txt):
        if x not in activities: activities.append(x)

# Find all deobfuscation outputs regardless of exact path.
deobf_files={}
for name in ("decoded-strings.json","interesting-strings.json","decoder-routines.json","report.json"):
    hits=[str(x) for x in (p/"work").rglob(name)]
    deobf_files[name]=hits

# Enumerate class prefixes and filter common third-party namespaces.
roots=[x for x in (p/"work").rglob("smali*") if x.is_dir() and x.name.startswith("smali")]
pref2=collections.Counter(); pref3=collections.Counter(); pref4=collections.Counter()
for root in roots:
    for f in root.rglob("*.smali"):
        try:
            parts=f.relative_to(root).with_suffix("").parts
        except Exception:
            continue
        if len(parts)>=2: pref2[".".join(parts[:2])] += 1
        if len(parts)>=3: pref3[".".join(parts[:3])] += 1
        if len(parts)>=4: pref4[".".join(parts[:4])] += 1

common_prefixes=(
 "android.","androidx.","kotlin.","kotlinx.","java.","javax.","org.jetbrains.",
 "com.google.","com.facebook.","com.bumptech.","com.squareup.","com.airbnb.",
 "com.amazonaws.","com.adjust.","com.appsflyer.","com.bytedance.","com.mbridge.",
 "com.iab.","com.alibaba.","com.aliyun.","com.cloud.","com.hisavana.",
 "com.bykv.","com.transsion.","okhttp3.","retrofit2.","dagger.","org.chromium."
)

def interesting(counter):
    rows=[]
    for k,v in counter.most_common():
        if k.startswith(common_prefixes): continue
        rows.append((k,v))
        if len(rows)>=40: break
    return rows

report={
 "project_id":p.name,
 "source":str(source) if source else None,
 "source_size":source.stat().st_size if source else None,
 "aapt_package":aapt_package,
 "aapt_app_label":aapt_app_label,
 "aapt_version":aapt_version,
 "manifest_packages":manifest_packages[:20],
 "application_names":application_names[:20],
 "activities_sample":activities[:50],
 "analysis_top_keys":sorted(list(analysis.keys()))[:100],
 "analysis_identity":analysis.get("identity"),
 "analysis_app":analysis.get("app"),
 "deobfuscation_files":deobf_files,
 "candidate_prefixes_2":interesting(pref2),
 "candidate_prefixes_3":interesting(pref3),
 "candidate_prefixes_4":interesting(pref4),
}
out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print(json.dumps(report,ensure_ascii=False))
PY

echo
echo "=== SUMMARY ==="
python3 - "$OUT/identity-$STAMP.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8"))
print("source=",x.get("source"))
print("source_size=",x.get("source_size"))
print("aapt_package=",x.get("aapt_package"))
print("aapt_app_label=",x.get("aapt_app_label"))
print("aapt_version=",x.get("aapt_version"))
print("manifest_packages=",x.get("manifest_packages"))
print("application_names=",x.get("application_names"))
print("deobfuscation_files:")
for k,v in x.get("deobfuscation_files",{}).items():
    print(" ",k,":",len(v))
print("candidate_prefixes_3:")
for k,v in (x.get("candidate_prefixes_3") or [])[:20]:
    print(" ",v,k)
print("candidate_prefixes_4:")
for k,v in (x.get("candidate_prefixes_4") or [])[:20]:
    print(" ",v,k)
PY

echo
echo CENTRAL_CRUNCHYROLL_IDENTITY_DIAGNOSTIC_V3_READY
echo "report=$OUT/identity-$STAMP.json"
