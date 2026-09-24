#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef/work/android-audit/decoded"
OUT="/var/lib/conector/xuper-startplay-callers.txt"
mkdir -p /var/lib/conector
: > "$OUT"

echo "XUPER_STARTPLAY_CALLERS" >> "$OUT"
echo "timestamp=$(date -Is)" >> "$OUT"

python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import re, sys

root=Path(sys.argv[1]); out=Path(sys.argv[2])
patterns = [
    re.compile(r'Lsb/b;->H\('),
    re.compile(r'Lsb/b;->S\('),
    re.compile(r'Lsb/b;->D0\('),
]
files=list(root.rglob("*.smali"))

def method_bounds(lines, idx):
    start=idx
    while start>=0 and not lines[start].startswith(".method"):
        start-=1
    end=idx
    while end<len(lines) and not lines[end].startswith(".end method"):
        end+=1
    if end<len(lines): end+=1
    return max(0,start), min(len(lines),end)

with out.open("a",encoding="utf-8") as fh:
    total=0
    for p in files:
        txt=p.read_text(encoding="utf-8",errors="ignore")
        if "Lsb/b;->" not in txt:
            continue
        lines=txt.splitlines(True)
        for i,line in enumerate(lines):
            if any(rx.search(line) for rx in patterns):
                s,e=method_bounds(lines,i)
                block="".join(lines[s:e])
                fh.write(f"\n===== CALLER {p.relative_to(root)} line {i+1} =====\n")
                fh.write(block[:26000])
                if len(block)>26000:
                    fh.write("\n...[method truncated]\n")
                total+=1
    fh.write(f"\nTOTAL_CALLERS={total}\n")

    fh.write("\n===== REQUEST BEAN CONSTRUCTION REFERENCES =====\n")
    needles=["StartPlayVODBean","StartPlayLiveBean","StartPlayVODResult","StartPlayLiveResult"]
    for needle in needles:
        fh.write(f"\n### {needle}\n")
        shown=0
        for p in files:
            txt=p.read_text(encoding="utf-8",errors="ignore")
            if needle not in txt: continue
            for n,line in enumerate(txt.splitlines(),1):
                if needle in line and ("new-instance" in line or "invoke-direct" in line or "invoke-virtual" in line or "check-cast" in line):
                    fh.write(f"{p.relative_to(root)}:{n}:{line.strip()}\n")
                    shown+=1
                    if shown>=80: break
            if shown>=80: break
        fh.write(f"COUNT_SHOWN={shown}\n")

fh=open(out,"a",encoding="utf-8")
fh.write("\nNOTE=static caller trace only; no live credentials, tokens, cookies, or license acquisition\n")
fh.close()
PY

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-startplay-callers.txt" || true
fi

echo "XUPER_STARTPLAY_CALLERS_READY"
wc -l "$OUT"
