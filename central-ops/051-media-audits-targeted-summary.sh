#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/media-audits-targeted-summary.txt"
mkdir -p /var/lib/conector
: > "$OUT"

echo "MEDIA_AUDITS_TARGETED_SUMMARY" >> "$OUT"
echo "timestamp=$(date -Is)" >> "$OUT"

python3 - "$OUT" <<'PY'
import json, re, sys
from pathlib import Path

out=Path(sys.argv[1])
projects=[
("xuper-main",Path("/home/ubuntu/Central/projects/20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef/canon/analysis.json")),
("xuper-clone",Path("/home/ubuntu/Central/projects/20260923-131847-xuper-20tv-204-99-2-20-para-20tv-20gratis-20clon-8adb13/canon/analysis.json")),
("xuper-amigonly",Path("/home/ubuntu/Central/projects/20260923-140402-xuper-amigonly-2-0-apk-acc315/canon/analysis.json")),
("crunchyroll",Path("/home/ubuntu/Central/projects/20260923-092511-crunchyroll-20v3-112-2-20-premium-apk-ecb4b7/canon/analysis.json")),
]

terms=re.compile(r'(content|program|episode|season|channel|epg|poster|image|playback|player|source|stream|media|network|http|retrofit|okhttp|api|domain|host|resolver)',re.I)

def short(v):
    s=str(v).replace("\n"," ").strip()
    return s[:220]

with out.open("a",encoding="utf-8") as fh:
    for name,path in projects:
        fh.write(f"\n=== {name} ===\n")
        if not path.is_file():
            fh.write(f"MISSING={path}\n")
            continue
        data=json.loads(path.read_text(encoding="utf-8"))
        hits=[]
        stack=[("$",data)]
        while stack:
            p,v=stack.pop()
            if isinstance(v,dict):
                for k,val in v.items():
                    np=f"{p}.{k}"
                    if terms.search(str(k)):
                        if isinstance(val,(str,int,float,bool)) or val is None:
                            hits.append((np,short(val)))
                        elif isinstance(val,list):
                            hits.append((np,f"[list:{len(val)}]"))
                        elif isinstance(val,dict):
                            hits.append((np,f"{{dict:{len(val)}}}"))
                    stack.append((np,val))
            elif isinstance(v,list):
                for i,val in enumerate(v[:250]):
                    stack.append((f"{p}[{i}]",val))
            elif isinstance(v,str) and terms.search(v) and len(v)<500:
                hits.append((p,short(v)))
        seen=set()
        compact=[]
        for item in hits:
            if item in seen: continue
            seen.add(item)
            compact.append(item)
        for p,val in compact[:260]:
            fh.write(f"{p} = {val}\n")
        fh.write(f"TOTAL_MATCHES={len(compact)}\n")
PY

echo >> "$OUT"
echo "NOTE=targeted summary of existing canon analyses; no files modified" >> "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-audits-targeted-summary.txt" || true
fi

cat "$OUT"
