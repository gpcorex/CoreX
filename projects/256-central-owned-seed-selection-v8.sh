#!/usr/bin/env bash
set -euo pipefail

RES=/home/ubuntu/Central/dependency_resolver_v1/resolve_android_dependencies.py
PID="${1:-20260923-092511-crunchyroll-20v3-112-2-20-premium-apk-ecb4b7}"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/owned-seed-selection-v8-$STAMP
mkdir -p "$BACKUP"
cp -a "$RES" "$BACKUP/resolve_android_dependencies.py.before"

echo "=== 1. REPLACE CORE SEED SELECTION WITH OWNERSHIP-AWARE V8 ==="
python3 - "$RES" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

pat=r'''        seeds=set\(\).*?        closure=set\(seeds\); direct=set\(\); q=deque\(\(d,0\) for d in seeds\)'''
rep='''        seeds=set()

        def useful_seed(d):
            # Never promote generated resource/binding classes to functional CORE.
            tail=d.rsplit("/",1)[-1]
            if tail.startswith("R$") or tail in {"R;","BuildConfig;","DataBinderMapperImpl;"}:
                return False
            if "/databinding/" in d.lower():
                return False
            return True

        # 1) Exact evidence-to-class matches, but only application-owned classes.
        for d,p in class_map.items():
            if not is_app_owned(d) or not useful_seed(d):
                continue
            rel=str(p.relative_to(decoded)); dot=dotted(d)
            if any(t and (rel in t or dot in t or d in t) for t in texts):
                seeds.add(d)

        # 2) Semantic fallback from the indexed smali contents.
        # This is what repacked/obfuscated apps need: names can be meaningless,
        # but owned classes still contain role-specific calls/strings.
        if len(seeds)<3:
            for score,d in keyword_scores.get(role,[]):
                if not is_app_owned(d) or not useful_seed(d):
                    continue
                seeds.add(d)
                if len(seeds)>=20:
                    break

        closure=set(seeds); direct=set(); q=deque((d,0) for d in seeds)'''

s2,n=re.subn(pat,rep,s,count=1,flags=re.S)
if n!=1:
    raise SystemExit(f"SEED_BLOCK_REPLACEMENT_FAILED count={n}")
p.write_text(s2,encoding="utf-8")
PY

python3 -m py_compile "$RES"
echo OWNED_SEED_SELECTION_V8_SOURCE_OK

echo "=== 2. RERUN RESOLVER ON TARGET PROJECT ==="
TMP=/tmp/owned-seed-v8-$STAMP.log
sudo -u ubuntu python3 "$RES" "$PID" 2>&1 | tee "$TMP"
LAST=$(tail -n1 "$TMP")

python3 - "$LAST" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x["ok"] is True
print("app_packages="+json.dumps(x.get("app_packages") or [],ensure_ascii=False))
owned=[]
for c in x.get("components") or []:
    print(f'{c["role"]}: core={c["seed_count"]} minimal={c["minimal_internal_count"]} shared={c["shared_count"]} external={c["external_count"]} framework={c["framework_count"]}')
    if int(c.get("seed_count") or 0)>0:
        owned.append(c["role"])
assert owned, "NO_VERIFIED_COMPONENTS_AFTER_V8"
print("verified_roles="+",".join(owned))
print("OWNED_SEED_SELECTION_V8_COMPONENTS_OK")
PY

echo "=== 3. VERIFY CORE DOES NOT USE GENERATED R CLASSES ==="
python3 - "$PID" <<'PY'
from pathlib import Path
import json,sys
p=Path("/home/ubuntu/Central/projects")/sys.argv[1]/"work"/"dependencies"
bad=[]
for pkg in p.glob("*/package.json"):
    try:x=json.load(open(pkg,encoding="utf-8"))
    except Exception:continue
    for row in x.get("classification") or []:
        if row.get("kind")!="CORE":continue
        d=row.get("descriptor") or ""
        tail=d.rsplit("/",1)[-1]
        if tail.startswith("R$") or tail in {"R;","BuildConfig;","DataBinderMapperImpl;"} or "/databinding/" in d.lower():
            bad.append(d)
assert not bad,bad[:20]
print("OWNED_SEED_SELECTION_V8_NO_GENERATED_CORE_OK")
PY

echo CENTRAL_OWNED_SEED_SELECTION_V8_READY
echo "project=$PID"
echo "backup=$BACKUP"
