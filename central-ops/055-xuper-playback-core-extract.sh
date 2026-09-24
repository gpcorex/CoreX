#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef/work/android-audit/decoded"
OUT="/var/lib/conector/xuper-playback-core-extract.txt"
mkdir -p /var/lib/conector
: > "$OUT"

echo "XUPER_PLAYBACK_CORE_EXTRACT" >> "$OUT"
echo "timestamp=$(date -Is)" >> "$OUT"

python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import re, sys

root=Path(sys.argv[1]); out=Path(sys.argv[2])

targets = [
    "smali_classes3/ud/n1.smali",
    "smali_classes3/ud/n1$y.smali",
    "smali_classes2/com/module/bean/SourceBean.smali",
    "smali_classes2/com/module/bean/DefinitionBean.smali",
    "smali_classes2/com/module/bean/PipVideoInfo.smali",
    "smali/com/request/result/StartPlayVODResult.smali",
    "smali/com/request/result/StartPlayLiveResult.smali",
    "smali/com/request/result/LiveAddress.smali",
    "smali_classes2/com/request/bean/StartPlayVODBean.smali",
    "smali_classes2/com/request/bean/StartPlayLiveBean.smali",
]

method_terms = re.compile(
    r'(startPlayVOD|startPlayLive|playUrl|addressLicense|license|mainAddr|sparedAddr|mediaCode|SourceBean|DefinitionBean|PipVideoInfo|setMedia|setVideo|setDataSource|getSelectSource|LiveAddress|contentId|seriesContentId|episodeNumberList|portalCode|authType|userToken|userId)',
    re.I
)

def emit_methods(path, fh):
    txt=path.read_text(encoding="utf-8", errors="ignore")
    lines=txt.splitlines(True)
    i=0; shown=0
    while i < len(lines):
        if lines[i].startswith(".method"):
            j=i+1
            while j < len(lines) and not lines[j].startswith(".end method"):
                j+=1
            if j < len(lines): j+=1
            block="".join(lines[i:j])
            if method_terms.search(block):
                fh.write(f"\n--- METHOD {path.relative_to(root)} :: {lines[i].strip()} ---\n")
                fh.write(block[:12000])
                if len(block)>12000:
                    fh.write("\n...[method truncated]\n")
                shown+=1
            i=j
        else:
            i+=1
    fh.write(f"\nMETHODS_SHOWN={shown}\n")

with out.open("a",encoding="utf-8") as fh:
    for rel in targets:
        p=root/rel
        fh.write(f"\n===== FILE {rel} =====\n")
        if p.is_file():
            emit_methods(p, fh)
        else:
            fh.write("MISSING\n")

    fh.write("\n===== GLOBAL EXACT REFERENCES =====\n")
    needles=["startPlayVOD","startPlayLive","setMedia(","setVideoPath","setAddressLicense","setPlayUrl","getPlayUrl","getAddressLicense"]
    files=list(root.rglob("*.smali"))
    for needle in needles:
        fh.write(f"\n### {needle}\n")
        count=0
        for p in files:
            txt=p.read_text(encoding="utf-8",errors="ignore")
            if needle not in txt: continue
            for n,line in enumerate(txt.splitlines(),1):
                if needle in line:
                    fh.write(f"{p.relative_to(root)}:{n}:{line.strip()}\n")
                    count+=1
                    if count>=50: break
            if count>=50: break
        fh.write(f"COUNT_SHOWN={count}\n")

fh=open(out,"a",encoding="utf-8")
fh.write("\nNOTE=focused static extraction only; no live auth/session material collected\n")
fh.close()
PY

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-playback-core-extract.txt" || true
fi

echo "XUPER_PLAYBACK_CORE_EXTRACT_READY"
wc -l "$OUT"
