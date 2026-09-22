#!/usr/bin/env bash
set -euo pipefail

AUD=/home/ubuntu/Central/auditor_v1
CANON=/home/ubuntu/Central/canon/v1
PROJECTS=/home/ubuntu/Central/projects
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/auditor-apk-v1-$STAMP
mkdir -p "$AUD" "$BACKUP"

echo "=== 1. INSTALL LIGHTWEIGHT APK AUDIT TOOLCHAIN ==="
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq unzip file aapt apktool apksigner >/tmp/auditor-v1-apt.log 2>&1 || {
  cat /tmp/auditor-v1-apt.log
  exit 1
}
command -v aapt >/dev/null
command -v apktool >/dev/null
command -v apksigner >/dev/null
echo APK_AUDIT_TOOLCHAIN_OK

echo "=== 2. INSTALL APK/XAPK AUDITOR V1 ==="
cat >"$AUD/audit_android.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, hashlib, json, os, re, shutil, subprocess, sys, time, zipfile
from pathlib import Path
import xml.etree.ElementTree as ET

PROJECTS=Path("/home/ubuntu/Central/projects")
CANON=Path("/home/ubuntu/Central/canon/v1")
VALIDATOR=CANON/"validate_canon.py"
ANDROID_NS="{http://schemas.android.com/apk/res/android}"

URL_RE=re.compile(rb'https?://[A-Za-z0-9._~:/?#\[\]@!$&\'()*+,;=%-]{4,}')
MEDIA_EXTS={".m3u8",".mpd",".mp4",".mkv",".webm",".ts",".aac",".mp3",".flac",".vtt",".srt"}

def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())

def run(cmd,timeout=120):
    try:
        cp=subprocess.run(cmd,text=True,capture_output=True,timeout=timeout)
        return cp.returncode,cp.stdout,cp.stderr
    except subprocess.TimeoutExpired as e:
        return 124,e.stdout or "",e.stderr or ""

def sha256(path:Path):
    h=hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda:f.read(1024*1024),b""):
            h.update(chunk)
    return h.hexdigest()

def ev_id(kind,locator):
    raw=(kind+"|"+locator).encode()
    return "ev."+hashlib.sha1(raw).hexdigest()[:12]

def add_evidence(a,kind,locator,tool,excerpt=None,hashv=None):
    eid=ev_id(kind,locator)
    if not any(x.get("id")==eid for x in a["evidence"]):
        a["evidence"].append({
            "id":eid,
            "kind":kind,
            "locator":locator,
            "excerpt":excerpt,
            "hash_sha256":hashv,
            "tool":tool,
            "observed_at":now_iso()
        })
    return eid

def find_apks(project_root:Path,kind:str):
    src=project_root/"source"
    if kind=="apk":
        xs=sorted(src.glob("*.apk"))
        if not xs:
            xs=[p for p in src.iterdir() if p.is_file()]
        return xs[:1]
    if kind=="xapk":
        xapks=sorted(src.glob("*.xapk"))
        if not xapks:
            return []
        out=project_root/"work"/"xapk-expanded"
        out.mkdir(parents=True,exist_ok=True)
        with zipfile.ZipFile(xapks[0]) as z:
            for n in z.namelist():
                if n.lower().endswith(".apk") and ".." not in Path(n).parts:
                    target=out/Path(n).name
                    with z.open(n) as r, target.open("wb") as w:
                        shutil.copyfileobj(r,w)
        apks=sorted(out.glob("*.apk"),key=lambda p:(0 if "base" in p.name.lower() else 1,p.name))
        return apks
    return []

def parse_badging(apk:Path):
    rc,out,err=run(["aapt","dump","badging",str(apk)],60)
    data={"raw":out if rc==0 else ""}
    if rc!=0:
        return data
    m=re.search(r"package: name='([^']+)' versionCode='([^']*)' versionName='([^']*)'",out)
    if m:
        data["package_name"],data["version_code"],data["version_name"]=m.groups()
    m=re.search(r"application-label(?:-[^:]*)?:'([^']*)'",out)
    if m:data["label"]=m.group(1)
    m=re.search(r"launchable-activity: name='([^']+)'",out)
    if m:data["launchable_activity"]=m.group(1)
    perms=re.findall(r"uses-permission: name='([^']+)'",out)
    data["permissions"]=sorted(set(perms))
    feats=re.findall(r"uses-feature: name='([^']+)'",out)
    data["features"]=sorted(set(feats))
    return data

def decode_apk(apk:Path,decoded:Path):
    if decoded.exists(): shutil.rmtree(decoded)
    rc,out,err=run(["apktool","d","-f","-o",str(decoded),str(apk)],180)
    return rc,out,err

def parse_manifest(path:Path):
    result={"activities":[],"services":[],"receivers":[],"providers":[],"permissions":[]}
    if not path.is_file():
        return result
    try:
        root=ET.parse(path).getroot()
    except Exception:
        return result
    pkg=root.attrib.get("package")
    if pkg: result["package_name"]=pkg
    for node in root.findall("uses-permission"):
        n=node.attrib.get(ANDROID_NS+"name")
        if n: result["permissions"].append(n)
    app=root.find("application")
    if app is not None:
        for tag,key in (("activity","activities"),("activity-alias","activities"),("service","services"),("receiver","receivers"),("provider","providers")):
            for node in app.findall(tag):
                n=node.attrib.get(ANDROID_NS+"name")
                if n: result[key].append(n)
    for k in ("activities","services","receivers","providers","permissions"):
        result[k]=sorted(set(result[k]))
    return result

def scan_zip(apk:Path):
    info={"dex":[],"native_libs":[],"resources":[],"assets":[],"media_files":[]}
    with zipfile.ZipFile(apk) as z:
        names=z.namelist()
        info["dex"]=sorted(n for n in names if re.fullmatch(r"classes\d*\.dex",Path(n).name))
        info["native_libs"]=sorted(n for n in names if n.startswith("lib/") and n.endswith(".so"))
        info["resources"]=sorted(n for n in names if n.startswith("res/"))[:500]
        info["assets"]=sorted(n for n in names if n.startswith("assets/"))[:500]
        info["media_files"]=sorted(n for n in names if Path(n).suffix.lower() in MEDIA_EXTS)[:300]
    return info

def scan_urls(paths:list[Path],limit=120):
    found=[]
    for p in paths:
        if not p.is_file(): continue
        try:
            data=p.read_bytes()
        except Exception:
            continue
        for m in URL_RE.finditer(data):
            try:u=m.group().decode("utf-8","replace")
            except Exception:continue
            if u not in found: found.append(u)
            if len(found)>=limit:return found
    return found

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("project_id")
    a=ap.parse_args()
    root=(PROJECTS/a.project_id).resolve()
    if root.parent!=PROJECTS.resolve() or not root.is_dir():
        raise SystemExit("PROJECT_NOT_FOUND:"+a.project_id)

    manifest=json.load(open(root/"project.json",encoding="utf-8"))
    kind=manifest.get("kind")
    if kind not in {"apk","xapk"}:
        raise SystemExit("ANDROID_AUDITOR_REQUIRES_APK_OR_XAPK")

    analysis_path=root/"canon"/"analysis.json"
    analysis=json.load(open(analysis_path,encoding="utf-8"))
    apks=find_apks(root,kind)
    if not apks:
        raise SystemExit("NO_APK_FOUND")

    primary=apks[0]
    work=root/"work"/"android-audit"
    work.mkdir(parents=True,exist_ok=True)
    decoded=work/"decoded"

    badging=parse_badging(primary)
    zipinfo=scan_zip(primary)
    rc,_,apktool_err=decode_apk(primary,decoded)
    mf=parse_manifest(decoded/"AndroidManifest.xml") if rc==0 else {"activities":[],"services":[],"receivers":[],"providers":[],"permissions":[]}

    analysis["source"]["package_name"]=badging.get("package_name") or mf.get("package_name")
    analysis["source"]["version"]=badging.get("version_name")
    analysis["source"]["hash_sha256"]=sha256(primary)
    analysis["identity"]["name"]=badging.get("label") or analysis["identity"].get("name") or primary.stem
    analysis["identity"]["platform"]="android"
    entry=badging.get("launchable_activity")
    analysis["identity"]["entrypoints"]=[entry] if entry else []

    perms=sorted(set((badging.get("permissions") or [])+(mf.get("permissions") or [])))
    analysis["security"]["permissions"]=perms

    ev_manifest=add_evidence(
        analysis,"manifest","AndroidManifest.xml","apktool" if rc==0 else "aapt",
        excerpt=("decoded" if rc==0 else (apktool_err or "")[:500])
    )

    apk_eid=add_evidence(
        analysis,"file",str(primary.relative_to(root)),"zipfile",
        excerpt="primary apk",hashv=sha256(primary)
    )

    for dex in zipinfo["dex"]:
        add_evidence(analysis,"file",dex,"zipfile",excerpt="DEX")
    for lib in zipinfo["native_libs"][:200]:
        add_evidence(analysis,"library",lib,"zipfile",excerpt="native library")
    for res in zipinfo["resources"][:200]:
        add_evidence(analysis,"resource",res,"zipfile")
    for asset in zipinfo["assets"][:200]:
        add_evidence(analysis,"resource",asset,"zipfile")

    activities=mf.get("activities") or ([entry] if entry else [])
    existing_if={x.get("id") for x in analysis.get("interfaces",[])}
    for name in activities[:300]:
        iid="if."+hashlib.sha1(name.encode()).hexdigest()[:12]
        if iid not in existing_if:
            analysis["interfaces"].append({
                "id":iid,
                "name":name,
                "kind":"activity",
                "parent_id":None,
                "entry":bool(entry and name==entry),
                "navigation_targets":[],
                "resource_refs":[],
                "evidence_refs":[ev_manifest],
                "confidence":"verified" if rc==0 else "medium"
            })

    for typ,names in (("service",mf.get("services",[])),("receiver",mf.get("receivers",[])),("provider",mf.get("providers",[]))):
        for name in names[:300]:
            bid="bh."+hashlib.sha1((typ+name).encode()).hexdigest()[:12]
            if not any(x.get("id")==bid for x in analysis.get("behaviors",[])):
                analysis["behaviors"].append({
                    "id":bid,
                    "name":name,
                    "trigger":typ,
                    "effect":None,
                    "state_changes":[],
                    "evidence_refs":[ev_manifest],
                    "confidence":"verified"
                })

    scan_paths=[primary]
    if rc==0:
        scan_paths += [p for p in decoded.rglob("*") if p.is_file() and p.stat().st_size<=5*1024*1024][:1200]
    urls=scan_urls(scan_paths)
    apis=[]
    for i,u in enumerate(urls):
        try:
            from urllib.parse import urlsplit
            z=urlsplit(u)
            base=f"{z.scheme}://{z.netloc}" if z.scheme and z.netloc else None
        except Exception:
            base=None
        if not base: continue
        if not any(x.get("base")==base for x in apis):
            eid=add_evidence(analysis,"endpoint",u,"strings-scan",excerpt=u[:300])
            apis.append({
                "id":"api."+hashlib.sha1(base.encode()).hexdigest()[:12],
                "base":base,
                "endpoints":[u],
                "auth_dependency":None,
                "evidence_refs":[eid],
                "confidence":"medium"
            })
        else:
            for x in apis:
                if x["base"]==base and u not in x["endpoints"]:
                    x["endpoints"].append(u)
    analysis["data"]["apis"]=apis

    codecs=set(analysis["media"].get("codecs") or [])
    for f in zipinfo["media_files"]:
        ext=Path(f).suffix.lower().lstrip(".")
        if ext: codecs.add(ext)
        add_evidence(analysis,"resource",f,"zipfile",excerpt="media-like resource")
    analysis["media"]["codecs"]=sorted(codecs)

    notes=[x for x in analysis.get("notes",[]) if x!="Pendiente de análisis por adaptador específico."]
    notes += [
        "ANDROID_AUDIT_V1_COMPLETE",
        f"apk_count={len(apks)}",
        f"dex_count={len(zipinfo['dex'])}",
        f"native_lib_count={len(zipinfo['native_libs'])}",
        f"activity_count={len(activities)}",
        f"service_count={len(mf.get('services',[]))}",
        f"receiver_count={len(mf.get('receivers',[]))}",
        f"provider_count={len(mf.get('providers',[]))}",
        f"url_count={len(urls)}",
        "Functional component grouping (catalog/search/player/etc.) is intentionally pending deeper code analysis."
    ]
    if rc!=0:
        notes.append("apktool_decode_failed:"+str(apktool_err)[:300])
    analysis["notes"]=list(dict.fromkeys(notes))

    analysis_path.write_text(json.dumps(analysis,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    report={
        "ok":True,
        "project_id":a.project_id,
        "kind":kind,
        "primary_apk":str(primary),
        "package_name":analysis["source"].get("package_name"),
        "version":analysis["source"].get("version"),
        "apk_count":len(apks),
        "dex_count":len(zipinfo["dex"]),
        "activities":len(activities),
        "services":len(mf.get("services",[])),
        "receivers":len(mf.get("receivers",[])),
        "providers":len(mf.get("providers",[])),
        "permissions":len(perms),
        "native_libs":len(zipinfo["native_libs"]),
        "urls":len(urls),
        "apktool_ok":rc==0,
        "analysis_path":str(analysis_path)
    }
    (work/"report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    manifest["status"]="AUDITED_STRUCTURAL_V1"
    manifest["updated_at"]=now_iso()
    (root/"project.json").write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(report,ensure_ascii=False))

if __name__=="__main__":
    main()
PY

chmod 755 "$AUD/audit_android.py"
python3 -m py_compile "$AUD/audit_android.py"
echo ANDROID_AUDITOR_V1_SOURCE_OK

echo "=== 3. INSTALL README ==="
cat >"$AUD/README.md" <<'EOF'
# Central Auditor V1 — Android structural adapter

Entrada: un proyecto Central ya ingestado como APK o XAPK.

Este primer adaptador completa el modelo canónico con evidencia estructural:
- package/version/label
- launchable activity
- permissions
- activities
- services
- receivers
- providers
- DEX
- native libraries
- resources/assets
- URLs/endpoints encontrados
- archivos de apariencia multimedia
- hash del APK
- evidencia trazable

No intenta todavía afirmar funciones como catálogo, búsqueda o reproductor sin evidencia
de código suficiente. Esa clasificación funcional será una capa posterior.
EOF

echo "=== 4. BUILD SYNTHETIC APK-LIKE FIXTURE ==="
FIX=/tmp/central-auditor-v1
rm -rf "$FIX"
mkdir -p "$FIX/res/layout" "$FIX/assets" "$FIX/lib/arm64-v8a"
cat >"$FIX/AndroidManifest.xml" <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="demo.central">
  <uses-permission android:name="android.permission.INTERNET"/>
  <application android:label="Central Demo">
    <activity android:name=".MainActivity">
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
    <service android:name=".DemoService"/>
  </application>
</manifest>
XML
printf 'dex\nhttps://api.example.test/catalog\n' >"$FIX/classes.dex"
printf 'layout' >"$FIX/res/layout/main.xml"
printf 'asset' >"$FIX/assets/demo.txt"
printf 'so' >"$FIX/lib/arm64-v8a/libdemo.so"
(cd "$FIX" && zip -qr /tmp/central-auditor-v1.apk .)

echo "=== 5. INGEST FIXTURE ==="
OUT=$(sudo -u ubuntu python3 /home/ubuntu/Central/ingest_v1/ingest.py /tmp/central-auditor-v1.apk --kind apk --name "Auditor Fixture")
echo "$OUT"
PID=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["project_id"])' <<<"$OUT")

echo "=== 6. AUDIT FIXTURE ==="
AOUT=$(sudo -u ubuntu python3 "$AUD/audit_android.py" "$PID")
echo "$AOUT"
AN="$PROJECTS/$PID/canon/analysis.json"
python3 "$CANON/validate_canon.py" "$AN"

python3 - "$AN" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8"))
assert x["source"]["kind"]=="apk",x
assert x["identity"]["platform"]=="android",x
assert any("classes.dex"==e.get("locator") for e in x["evidence"]),x["evidence"]
assert any(e.get("kind")=="library" and "libdemo.so" in e.get("locator","") for e in x["evidence"]),x["evidence"]
assert any("ANDROID_AUDIT_V1_COMPLETE"==n for n in x["notes"]),x["notes"]
print("ANDROID_AUDITOR_V1_CANON_OK")
PY

echo CENTRAL_ANDROID_AUDITOR_V1_READY
echo "auditor=$AUD/audit_android.py"
echo "backup=$BACKUP"
