#!/usr/bin/env bash
set -euo pipefail

RES=/home/ubuntu/Central/dependency_resolver_v1/resolve_android_dependencies.py
PID="${1:-20260923-092511-crunchyroll-20v3-112-2-20-premium-apk-ecb4b7}"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/multi-ownership-v6-$STAMP
mkdir -p "$BACKUP"
cp -a "$RES" "$BACKUP/resolve_android_dependencies.py.before"

echo "=== 1. PATCH MULTI-ROOT APP OWNERSHIP ==="
python3 - "$RES" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

anchor='''def is_framework(d):
    return d.startswith(FRAMEWORK_PREFIXES)
'''
insert='''def is_framework(d):
    return d.startswith(FRAMEWORK_PREFIXES)

KNOWN_EXTERNAL_PREFIXES=(
 "Landroid/","Landroidx/","Ljava/","Ljavax/","Lkotlin/","Lkotlinx/",
 "Lcom/google/","Lcom/facebook/","Lcom/bumptech/","Lcom/squareup/",
 "Lcom/amazonaws/","Lcom/bytedance/","Lcom/mbridge/","Lcom/iab/",
 "Lcom/alibaba/","Lcom/aliyun/","Lcom/cloud/","Lcom/hisavana/",
 "Lcom/bykv/","Lokhttp3/","Lretrofit2/","Lorg/chromium/"
)

def _root3(name):
    parts=[x for x in str(name or "").strip(".").split(".") if x]
    if len(parts)>=3:return ".".join(parts[:3])
    return ".".join(parts)

def infer_app_packages(root, analysis, decoded):
    out=[]
    def add(x):
        x=str(x or "").strip()
        if x and x not in out: out.append(x)

    pkg=recursive_package_name(analysis) or ""
    add(pkg)

    # Manifest is the authoritative source for application/component class names.
    manifests=list(decoded.rglob("AndroidManifest.xml"))
    import re as _re
    for mf in manifests[:8]:
        try:txt=mf.read_text(encoding="utf-8",errors="ignore")
        except Exception:continue
        mm=_re.search(r'<manifest[^>]*\\bpackage="([^"]+)"',txt)
        manifest_pkg=mm.group(1) if mm else pkg
        if manifest_pkg:add(manifest_pkg)

        am=_re.search(r'<application[^>]*android:name="([^"]+)"',txt)
        if am:
            n=am.group(1)
            if n.startswith(".") and manifest_pkg:n=manifest_pkg+n
            elif "." not in n and manifest_pkg:n=manifest_pkg+"."+n
            add(_root3(n.rsplit(".",1)[0]))

        # Repeated namespaces among manifest components are strong first-party hints.
        counts={}
        for n in _re.findall(r'<(?:activity|service|receiver|provider)[^>]*android:name="([^"]+)"',txt):
            if n.startswith(".") and manifest_pkg:n=manifest_pkg+n
            elif "." not in n and manifest_pkg:n=manifest_pkg+"."+n
            r=_root3(n.rsplit(".",1)[0])
            if r: counts[r]=counts.get(r,0)+1
        for r,c in sorted(counts.items(),key=lambda kv:(-kv[1],kv[0])):
            desc="L"+r.replace(".","/")+"/"
            if c>=2 and not desc.startswith(KNOWN_EXTERNAL_PREFIXES):
                add(r)

    return out

def app_descriptors(packages):
    return tuple("L"+x.replace(".","/")+"/" for x in packages if x)

'''
if anchor not in s:
    raise SystemExit("FRAMEWORK_ANCHOR_NOT_FOUND")
s=s.replace(anchor,insert,1)

old='''    package_name=recursive_package_name(analysis) or ""
    app_prefix=("L"+package_name.replace(".","/")+"/") if package_name else ""
'''
new='''    app_packages=infer_app_packages(root,analysis,decoded)
    package_name=(app_packages[0] if app_packages else "")
    app_prefixes=app_descriptors(app_packages)

    def is_app_owned(d):
        return bool(app_prefixes) and d.startswith(app_prefixes)
'''
if old not in s:
    raise SystemExit("PACKAGE_PREFIX_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

s=s.replace('owned=[d for _,d in candidates if app_prefix and d.startswith(app_prefix)]',
            'owned=[d for _,d in candidates if is_app_owned(d)]')
s=s.replace('if app_prefix:\n            seeds={d for d in seeds if d.startswith(app_prefix)}',
            'if app_prefixes:\n            seeds={d for d in seeds if is_app_owned(d)}')
s=s.replace('elif app_prefix and not d.startswith(app_prefix):kind="EXTERNAL"',
            'elif app_prefixes and not is_app_owned(d):kind="EXTERNAL"')

# Expose ownership roots in resolver output.
old2='''      "ok":True,"project_id":args.project_id,"component_count":len(resolved),
      "app_package":package_name or None,"components":resolved
'''
new2='''      "ok":True,"project_id":args.project_id,"component_count":len(resolved),
      "app_package":package_name or None,"app_packages":app_packages,"components":resolved
'''
if old2 in s:
    s=s.replace(old2,new2,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$RES"
echo MULTI_OWNERSHIP_V6_SOURCE_OK

echo "=== 2. RERUN RESOLVER ON CRUNCHYROLL PROJECT ==="
TMP=/tmp/multi-ownership-v6-$STAMP.log
sudo -u ubuntu python3 "$RES" "$PID" 2>&1 | tee "$TMP"
LAST=$(tail -n1 "$TMP")

python3 - "$LAST" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x["ok"] is True
print("app_package="+str(x.get("app_package")))
print("app_packages="+json.dumps(x.get("app_packages") or [],ensure_ascii=False))
for c in x.get("components") or []:
    print(f'{c["role"]}: core={c["seed_count"]} minimal={c["minimal_internal_count"]} external={c["external_count"]} framework={c["framework_count"]}')
print("MULTI_OWNERSHIP_V6_RESOLVER_OK")
PY

echo "=== 3. VERIFY AT LEAST ONE OWNED COMPONENT ==="
python3 - "$LAST" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
owned=[c for c in x.get("components",[]) if int(c.get("seed_count") or 0)>0]
assert owned, "NO_OWNED_COMPONENTS_AFTER_MULTI_ROOT_INFERENCE"
print("owned_roles="+",".join(c["role"] for c in owned))
print("MULTI_OWNERSHIP_V6_CONFIRMED_COMPONENTS_OK")
PY

echo CENTRAL_MULTI_OWNERSHIP_V6_READY
echo "project=$PID"
echo "backup=$BACKUP"
