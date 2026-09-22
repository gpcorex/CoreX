#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/auditor_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/android-auditor-v1-zip-fix-$STAMP
mkdir -p "$BACKUP"

echo "=== 1. INSTALL MISSING ZIP TOOL ==="
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq zip >/tmp/android-auditor-v1-zip-install.log 2>&1 || {
  cat /tmp/android-auditor-v1-zip-install.log
  exit 1
}
command -v zip >/dev/null
echo ANDROID_AUDITOR_ZIP_TOOL_OK

echo "=== 2. VERIFY EXISTING AUDITOR INSTALL ==="
test -x "$ROOT/audit_android.py"
python3 -m py_compile "$ROOT/audit_android.py"
echo ANDROID_AUDITOR_V1_EXISTING_INSTALL_OK

echo "=== 3. REBUILD SYNTHETIC APK-LIKE FIXTURE ==="
FIX=/tmp/central-auditor-v1
rm -rf "$FIX" /tmp/central-auditor-v1.apk
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
test -s /tmp/central-auditor-v1.apk
echo ANDROID_AUDITOR_FIXTURE_ZIP_OK

echo "=== 4. INGEST FIXTURE ==="
OUT=$(sudo -u ubuntu python3 /home/ubuntu/Central/ingest_v1/ingest.py /tmp/central-auditor-v1.apk --kind apk --name "Auditor Fixture")
echo "$OUT"
PID=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["project_id"])' <<<"$OUT")

echo "=== 5. AUDIT FIXTURE ==="
AOUT=$(sudo -u ubuntu python3 "$ROOT/audit_android.py" "$PID")
echo "$AOUT"
AN="/home/ubuntu/Central/projects/$PID/canon/analysis.json"
python3 /home/ubuntu/Central/canon/v1/validate_canon.py "$AN"

python3 - "$AN" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8"))
assert x["source"]["kind"]=="apk",x
assert x["identity"]["platform"]=="android",x
assert any("classes.dex"==e.get("locator") for e in x["evidence"]),x["evidence"]
assert any(e.get("kind")=="library" and "libdemo.so" in e.get("locator","") for e in x["evidence"]),x["evidence"]
assert any("ANDROID_AUDIT_V1_COMPLETE"==n for n in x["notes"]),x["notes"]
print("ANDROID_AUDITOR_V1_CANON_RETEST_OK")
PY

echo CENTRAL_ANDROID_AUDITOR_V1_ZIP_FIXED_READY
echo "backup=$BACKUP"
