#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/media-audits-compact.txt"
mkdir -p /var/lib/conector
: > "$OUT"

echo "MEDIA_AUDITS_COMPACT" >> "$OUT"
echo "timestamp=$(date -Is)" >> "$OUT"

python3 - "$OUT" <<'PY'
import json, re, sys
from pathlib import Path

projects=[
("xuper-main",Path("/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef/canon/analysis.json")),
("xuper-clone",Path("/home/ubuntu/Central/projects/20260923-131847-xuper-20tv-204-99-2-20-para-20tv-20gratis-20clon-8adb13/canon/analysis.json")),
("xuper-amigonly",Path("/home/ubuntu/Central/projects/20260923-140402-xuper-amigonly-2-0-apk-acc315/canon/analysis.json")),
("crunchyroll-alt",Path("/home/ubuntu/Central/projects/20260923-092511-crunchyroll-20v3-112-2-20-premium-apk-ecb4b7/canon/analysis.json")),
]

interesting=re.compile(r'(assetList|simpleProgramList|episodeList|contentId|channelCode|liveAddressList|programList|poster|image|IjkMediaPlayer|ExoPlayer|media3|mpd|m3u8|retrofit|okhttp|domain_test|player|stream|endpoint|base)',re.I)

def walk(v,path="$"):
    if isinstance(v,dict):
        for k,val in v.items():
            yield from walk(val,f"{path}.{k}")
    elif isinstance(v,list):
        for i,val in enumerate(v[:400]):
            yield from walk(val,f"{path}[{i}]")
    else:
        yield path,v

with open(sys.argv[1],"a",encoding="utf-8") as out:
    for name,path in projects:
        out.write(f"\n=== {name} ===\n")
        if not path.is_file():
            out.write("MISSING\n"); continue
        data=json.loads(path.read_text(encoding="utf-8"))
        seen=set(); n=0
        for p,v in walk(data):
            s=str(v)
            if interesting.search(p) or interesting.search(s):
                line=f"{p} = {s[:180].replace(chr(10),' ')}"
                if line in seen: continue
                seen.add(line)
                out.write(line+"\n")
                n+=1
                if n>=120: break
        out.write(f"shown={n}\n")
PY

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-audits-compact.txt" || true
fi
cat "$OUT"
