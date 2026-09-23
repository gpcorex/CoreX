#!/usr/bin/env bash
set -euo pipefail

PID=20260923-104504-xupertv-n0f4c3-v6-73-0-apk-e216ef
ROOT=/home/ubuntu/Central/projects/$PID
OUT=/var/lib/conector/xuper-content-path-v1.txt

python3 - "$ROOT" >"$OUT" <<'PY'
from pathlib import Path
import json,re,sys

root=Path(sys.argv[1])
print("XUPER_CONTENT_PATH_V1")
print("project_id="+root.name)
print()

roles=["catalog","detail","data_source","stream_resolution","player","authentication","subtitles","search"]

def load(p):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None

def one_line(s,n=180):
    s=re.sub(r"\s+"," ",str(s)).strip()
    return s[:n]

for role in roles:
    base=root/"work"/"component-packages"/role
    print(f"[ROLE {role}]")
    if not base.exists():
        print("missing=true")
        print()
        continue
    manifest=load(base/"manifest.json") or {}
    refined=load(base/"REFINED"/"refined-contract.json") or {}
    iface=load(base/"INTERFACE"/"interface.json") or {}
    print("name="+str(manifest.get("name") or refined.get("name") or role))
    print("status="+str(refined.get("status") or manifest.get("status") or "unknown"))
    sm=refined.get("summary") or {}
    if sm:
        for k in ("entrypoint_count","reachable_method_count","reachable_external_call_count","reachable_framework_call_count","reachable_app_other_call_count","reachable_permission_count"):
            if k in sm: print(f"{k}={sm.get(k)}")
    net=refined.get("network") or {}
    hosts=net.get("hosts_observed_on_reachable_paths") or []
    if hosts: print("hosts="+", ".join(map(str,hosts[:20])))
    perms=[p.get("permission") for p in (refined.get("permissions") or []) if p.get("status")=="observed_on_reachable_path"]
    if perms: print("permissions="+", ".join(perms[:20]))
    ext=refined.get("external_calls_reachable") or []
    if ext:
        print("top_external_calls:")
        for x in ext[:20]:
            print("  - "+one_line(x.get("target"))+" x"+str(x.get("occurrences")))
    ops=iface.get("operations") or []
    if iface:
        print("interface_status="+str(iface.get("status")))
        print("interface_operation_count="+str(len(ops)))
        for op in ops[:12]:
            print("  op="+one_line(op.get("name")))
    print()

print("[CROSS_ROLE_HINTS]")
targets=("catalog","detail","data_source","stream_resolution","player","authentication")
terms=("http://","https://","play","player","stream","m3u8","mpd","manifest","token","auth","login","vod","detail","catalog","shelve","asset","episode","season")
decoded=root/"work"/"android-audit"/"decoded"
hits=[]
if decoded.exists():
    for p in decoded.rglob("*.smali"):
        try:
            txt=p.read_text(encoding="utf-8",errors="ignore")
        except Exception:
            continue
        low=txt.lower()
        score=sum(1 for t in terms if t in low)
        if score>=4:
            rel=str(p.relative_to(decoded))
            # capture only a few informative lines
            lines=[]
            for i,line in enumerate(txt.splitlines(),1):
                ll=line.lower()
                if any(t in ll for t in terms):
                    lines.append(f"{i}:{one_line(line,220)}")
                    if len(lines)>=6: break
            hits.append((score,rel,lines))
hits.sort(reverse=True)
for score,rel,lines in hits[:25]:
    print(f"file={rel} score={score}")
    for line in lines: print("  "+line)

print()
print("[ASSESSMENT_HINTS]")
print("catalog_sync_candidate=true if catalog/data_source expose stable network-backed calls or host evidence")
print("stream_resolution_candidate=true if stream_resolution/player expose reachable network or resolver calls")
print("auth_dependency=true if authentication is on the reachable path for catalog or stream resolution")
print("note=This report maps observed behavior only; it does not bypass DRM, authentication, signatures, or access controls.")
PY

/usr/local/sbin/conector-publish-result "$OUT" "vm-results/xuper-content-path-v1.txt" || true
echo XUPER_CONTENT_PATH_V1_DONE
