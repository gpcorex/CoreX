#!/usr/bin/env bash
set -euo pipefail

PID="${1:-20260923-092511-crunchyroll-20v3-112-2-20-premium-apk-ecb4b7}"
P="/home/ubuntu/Central/projects/$PID"
DEC="$P/work/android-audit/decoded"
OUT="$P/work/diagnostics"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

echo "=== CENTRAL OWNERSHIP KEYWORD PROBE V7 ==="
echo "project=$PID"
test -d "$DEC"

python3 - "$DEC" "$OUT/ownership-keyword-probe-$STAMP.json" <<'PY'
from pathlib import Path
import json,re,sys,collections

dec=Path(sys.argv[1]); out=Path(sys.argv[2])

ROOTS=[
 "com.community.oneroom",
 "com.transsion.subroom",
 "com.transsion.usercenter",
 "com.transsion.home",
 "com.transsion.room",
 "com.transsion.publish",
 "com.transsnet.downloader",
 "com.transsnet.login",
 "com.transsion.player",
 "com.transsion.moviedetail",
 "com.transsion.shorttv",
 "com.transsion.ugcvideodetail",
 "com.transsion.videodetail",
]
DESCS=tuple("L"+r.replace(".","/")+"/" for r in ROOTS)

WORDS={
 "data_source":["api","endpoint","retrofit","okhttp","graphql","repository","datasource","http"],
 "downloads":["download","offline"],
 "analytics":["analytics","telemetry","crashlytics","sentry"],
 "player":["player","playback","exo","media"],
}

CLASS_RE=re.compile(r'^\.class\s+.*?\s+(L[^;]+;)',re.M)
tot=0; owned=0
root_counts=collections.Counter()
role_hits={k:[] for k in WORDS}
role_totals=collections.Counter()

for f in dec.rglob("*.smali"):
    try: txt=f.read_text(encoding="utf-8",errors="ignore")
    except Exception: continue
    m=CLASS_RE.search(txt)
    if not m: continue
    d=m.group(1); tot+=1
    matched=None
    for r,dp in zip(ROOTS,DESCS):
        if d.startswith(dp):
            matched=r; break
    if not matched: continue
    owned+=1; root_counts[matched]+=1
    low=txt.lower()
    for role,kws in WORDS.items():
        score=sum(low.count(k) for k in kws)
        if score:
            role_totals[role]+=1
            if len(role_hits[role])<30:
                role_hits[role].append({"class":d,"root":matched,"score":score})

report={
 "total_classes":tot,
 "owned_classes":owned,
 "root_counts":root_counts.most_common(),
 "role_owned_hit_counts":dict(role_totals),
 "role_samples":role_hits,
}
out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print(json.dumps(report,ensure_ascii=False))
PY

echo
echo "=== SUMMARY ==="
python3 - "$OUT/ownership-keyword-probe-$STAMP.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8"))
print("total_classes=",x["total_classes"])
print("owned_classes=",x["owned_classes"])
print("root_counts:")
for k,v in x["root_counts"]:
    print(" ",v,k)
print("role_owned_hit_counts:")
for k,v in x["role_owned_hit_counts"].items():
    print(" ",k,v)
print("role_samples:")
for role,rows in x["role_samples"].items():
    print(" ",role)
    for r in rows[:8]:
        print("   ",r["score"],r["class"])
PY

echo
echo CENTRAL_OWNERSHIP_KEYWORD_PROBE_V7_READY
echo "report=$OUT/ownership-keyword-probe-$STAMP.json"
