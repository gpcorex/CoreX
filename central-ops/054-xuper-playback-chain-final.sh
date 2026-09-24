#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef/work/android-audit/decoded"
OUT="/var/lib/conector/xuper-playback-chain-final.txt"
mkdir -p /var/lib/conector
: > "$OUT"

echo "XUPER_PLAYBACK_CHAIN_FINAL" >> "$OUT"
echo "timestamp=$(date -Is)" >> "$OUT"
echo "root=$ROOT" >> "$OUT"

if [ ! -d "$ROOT" ]; then
  echo "ERROR=decoded_root_missing" >> "$OUT"
  exit 1
fi

python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import re, sys

root=Path(sys.argv[1]); out=Path(sys.argv[2])

needles=[
 "startPlayVOD","startPlayLive","StartPlayVOD","StartPlayLive",
 "PipVideoInfo","setPlayUrl","getPlayUrl","setAddressLicense","getAddressLicense",
 "DefinitionBean","SourceBean","LiveAddress","setVideoPath","VodPlayerWindow"
]

files=list(root.rglob("*.smali"))

def context(lines, i, radius=12):
    lo=max(0,i-radius); hi=min(len(lines),i+radius+1)
    return "".join(f"{n+1:05d}: {lines[n]}" for n in range(lo,hi))

with out.open("a",encoding="utf-8") as fh:
    for needle in needles:
        fh.write(f"\n===== {needle} =====\n")
        hits=0
        for p in files:
            try:
                txt=p.read_text(encoding="utf-8",errors="ignore")
            except Exception:
                continue
            if needle not in txt:
                continue
            lines=txt.splitlines(True)
            for i,line in enumerate(lines):
                if needle not in line:
                    continue
                rel=p.relative_to(root)
                fh.write(f"\nFILE={rel}\n")
                fh.write(context(lines,i))
                hits+=1
                if hits>=12: break
            if hits>=12: break
        fh.write(f"HITS_SHOWN={hits}\n")

    # Find direct callers that mention both playback-result concepts and player setters.
    fh.write("\n===== CROSS_LINK_CANDIDATES =====\n")
    cand=0
    for p in files:
        try:
            txt=p.read_text(encoding="utf-8",errors="ignore")
        except Exception:
            continue
        score=sum(1 for n in ["StartPlayVOD","PipVideoInfo","setPlayUrl","setAddressLicense","setVideoPath","getPlayUrl"] if n in txt)
        if score>=2:
            fh.write(f"{score}|{p.relative_to(root)}\n")
            cand+=1
    fh.write(f"CANDIDATE_FILES={cand}\n")

fh=open(out,"a",encoding="utf-8")
fh.write("\nNOTE=static call-chain extraction only; no credentials, tokens, cookies, or live requests collected\n")
fh.close()
PY

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-playback-chain-final.txt" || true
fi

echo "XUPER_PLAYBACK_CHAIN_FINAL_READY"
wc -l "$OUT"
