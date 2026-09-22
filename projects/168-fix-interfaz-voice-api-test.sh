#!/usr/bin/env bash
set -euo pipefail

APP=/home/ubuntu/Interfaz
SERVER="$APP/server.py"
NATIVE=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/interfaz-voice-test-fix-$STAMP

mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. VERIFY INTERFAZ PATCH IS PRESENT ==="
grep -q '/api/transcribe' "$SERVER"
grep -q 'id="mic"' "$SERVER"
python3 -m py_compile "$SERVER"
echo INTERFAZ_VOICE_PATCH_PRESENT_OK

echo "=== 2. FIX API TEST TO AVOID ARGUMENT LIST LIMIT ==="
FIX=/tmp/central-stt-proof.wav
test -s "$FIX" || espeak-ng -w "$FIX" -s 135 -v en-us "central voice test seven three one"

REQ=/tmp/interfaz-transcribe-request.json
python3 - "$FIX" "$REQ" <<'PY'
import base64,json,sys
src,dst=sys.argv[1],sys.argv[2]
with open(src,"rb") as f:
    b64=base64.b64encode(f.read()).decode("ascii")
with open(dst,"w",encoding="utf-8") as f:
    json.dump({"audio_base64":b64,"suffix":".wav"},f,separators=(",",":"))
PY

OUT=$(curl -fsS --max-time 120   -H 'Content-Type: application/json'   --data-binary @"$REQ"   http://127.0.0.1:8791/api/transcribe)
echo "$OUT"

OUT_JSON="$OUT" python3 - <<'PY'
import json,os,re
x=json.loads(os.environ["OUT_JSON"])
assert x["ok"] is True,x
assert x["capability"]=="stt",x
assert x.get("model_ref"),x
t=re.sub(r"[^a-z0-9 ]+"," ",x["text"].lower())
for w in ("central","voice","test"):
    assert w in t.split(),(w,x)
assert ("731" in t.split()) or all(w in t.split() for w in ("seven","three","one")),(x,)
print("INTERFAZ_TRANSCRIBE_API_OK")
print("model_ref="+x["model_ref"])
print("text="+x["text"])
PY

echo "=== 3. PUBLIC INTERFAZ CHECK ==="
curl -fsS --max-time 15 https://cen-tral.duckdns.org/interfaz/ | grep -q 'id="mic"'
echo INTERFAZ_MIC_PUBLIC_OK

echo "=== 4. SERVICE CHECK ==="
systemctl is-active interfaz.service
curl -fsS --max-time 5 http://127.0.0.1:8791/api/health
echo
echo INTERFAZ_SERVICE_OK

cat >"$NATIVE/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "interfaz-voice-v1-test-fix",
  "stt_verified_models": 2,
  "interfaz_transcribe_endpoint": true,
  "browser_microphone": true,
  "voice_to_text": true,
  "test_transport": "json-file-via-data-binary",
  "active": true
}
EOF

echo CENTRAL_INTERFAZ_VOICE_V1_READY
echo "URL=https://cen-tral.duckdns.org/interfaz/"
echo "backup=$BACKUP"
