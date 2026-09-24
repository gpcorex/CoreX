#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef/work/android-audit/decoded"
OUT="/var/lib/conector/xuper-startplay-methods.txt"
mkdir -p /var/lib/conector
: > "$OUT"

echo "XUPER_STARTPLAY_METHODS" >> "$OUT"
echo "timestamp=$(date -Is)" >> "$OUT"

python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys

root=Path(sys.argv[1]); out=Path(sys.argv[2])
targets=[
    root/"smali/ud/n1.smali",
    root/"smali_classes2/sb/b.smali",
]

def method_blocks(txt):
    lines=txt.splitlines(True)
    i=0
    while i < len(lines):
        if lines[i].startswith(".method"):
            start=i; i+=1
            while i < len(lines) and not lines[i].startswith(".end method"):
                i+=1
            if i < len(lines): i+=1
            yield start+1, "".join(lines[start:i])
        else:
            i+=1

with out.open("a", encoding="utf-8") as fh:
    for p in targets:
        fh.write(f"\n===== FILE {p.relative_to(root)} =====\n")
        if not p.is_file():
            fh.write("MISSING\n")
            continue
        txt=p.read_text(encoding="utf-8", errors="ignore")
        for line_no, block in method_blocks(txt):
            if "startPlayVOD" in block or "startPlayLive" in block:
                fh.write(f"\n--- METHOD line {line_no} ---\n")
                fh.write(block[:30000])
                if len(block) > 30000:
                    fh.write("\n...[method truncated]\n")

    fh.write("\n===== NEARBY STARTPLAY STRINGS =====\n")
    for p in root.rglob("*.smali"):
        try:
            txt=p.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        if "startPlayVOD" not in txt and "startPlayLive" not in txt:
            continue
        lines=txt.splitlines()
        for i,line in enumerate(lines):
            if "startPlayVOD" in line or "startPlayLive" in line:
                lo=max(0,i-20); hi=min(len(lines),i+21)
                fh.write(f"\nFILE={p.relative_to(root)} line={i+1}\n")
                for n in range(lo,hi):
                    fh.write(f"{n+1:05d}: {lines[n]}\n")

fh=open(out,"a",encoding="utf-8")
fh.write("\nNOTE=focused static extraction around startPlayVOD/startPlayLive only\n")
fh.close()
PY

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-startplay-methods.txt" || true
fi

echo "XUPER_STARTPLAY_METHODS_READY"
wc -l "$OUT"
