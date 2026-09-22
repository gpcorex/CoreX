#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/stt-semantic-proof-v2-$STAMP

mkdir -p "$BACKUP"
cp -a "$DEST/voice_stt_verify.py" "$BACKUP/voice_stt_verify.py" 2>/dev/null || true

echo "=== 1. FIX STT VERIFICATION: WORDS OR EQUIVALENT DIGITS ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/voice_stt_verify.py")
s=p.read_text(encoding="utf-8")

old='''EXPECTED=("central","voice","test","seven","three","one")

def norm(s):
    return re.sub(r"[^a-z0-9 ]+"," ",(s or "").lower()).split()
'''

new='''EXPECTED_WORDS=("central","voice","test")
EXPECTED_NUMBER_WORDS=("seven","three","one")

def norm(s):
    return re.sub(r"[^a-z0-9 ]+"," ",(s or "").lower()).split()

def transcript_matches(text):
    words=norm(text)
    if not all(x in words for x in EXPECTED_WORDS):
        return False
    joined=" ".join(words)
    number_ok=(
        all(x in words for x in EXPECTED_NUMBER_WORDS)
        or "731" in words
        or "7 3 1" in joined
    )
    return number_ok
'''

if old not in s:
    raise SystemExit("STT_EXPECTED_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)

old2='''    words=norm(text)
    ok=all(x in words for x in EXPECTED)
    return ok,text,obj
'''
new2='''    ok=transcript_matches(text)
    return ok,text,obj
'''
if old2 not in s:
    raise SystemExit("STT_MATCH_ANCHOR_NOT_FOUND")
s=s.replace(old2,new2,1)

p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$DEST/voice_stt_verify.py"
echo STT_SEMANTIC_MATCHER_OK

echo "=== 2. RERUN FUNCTIONAL STT PROOF ==="
FIX=/tmp/central-stt-proof.wav
test -s "$FIX" || { espeak-ng -w "$FIX" -s 135 -v en-us "central voice test seven three one"; }
sudo -u ubuntu PYTHONPATH="$DEST" python3 "$DEST/voice_stt_verify.py" "$FIX"
echo STT_FUNCTIONAL_PROOF_V2_OK

echo "=== 3. INSTALL TRANSCRIPTION CLI IF PREVIOUS SCRIPT STOPPED EARLY ==="
cat >"$DEST/transcribe.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, subprocess
from config import load_settings
from providers import ProviderRegistry

STATE="/home/ubuntu/Central/state/providers.json"

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("audio")
    args=ap.parse_args()

    s=load_settings()
    r=ProviderRegistry(s.groq_key,s.openrouter_key,STATE)
    refs=[ref for ref in r.all_discovered_refs() if "stt" in r.verified_capabilities(ref)]
    if not refs:
        raise SystemExit("NO_VERIFIED_STT_ROUTE")

    refs.sort(key=lambda x:(0 if x.endswith("whisper-large-v3-turbo") else 1,x))
    ref=refs[0]
    provider,model=ref.split("/",1)
    if provider!="groq":
        raise SystemExit("UNSUPPORTED_STT_PROVIDER:"+provider)

    cmd=[
      "curl","-fsS","--max-time","120",
      "-H",f"Authorization: Bearer {s.groq_key}",
      "-F",f"file=@{args.audio}",
      "-F",f"model={model}",
      "-F","response_format=json",
      "https://api.groq.com/openai/v1/audio/transcriptions",
    ]
    cp=subprocess.run(cmd,text=True,capture_output=True)
    if cp.returncode!=0:
        raise SystemExit(cp.stderr.strip() or "STT_REQUEST_FAILED")
    obj=json.loads(cp.stdout)
    print(json.dumps({
      "ok":True,
      "provider":provider,
      "model":model,
      "model_ref":ref,
      "capability":"stt",
      "text":obj.get("text",""),
    },ensure_ascii=False))

if __name__=="__main__":
    main()
PY
chmod 755 "$DEST/transcribe.py"
python3 -m py_compile "$DEST/transcribe.py"
echo TRANSCRIPTION_CLI_INSTALLED

echo "=== 4. LIVE CLI PROOF ==="
OUT=$(sudo -u ubuntu PYTHONPATH="$DEST" python3 "$DEST/transcribe.py" "$FIX")
echo "$OUT"
OUT_JSON="$OUT" python3 - <<'PY'
import json,os,re
x=json.loads(os.environ["OUT_JSON"])
assert x["ok"] is True,x
t=re.sub(r"[^a-z0-9 ]+"," ",x["text"].lower())
for w in ("central","voice","test"):
    assert w in t.split(),(w,x)
assert ("731" in t.split()) or all(w in t.split() for w in ("seven","three","one")),(x,)
print("TRANSCRIPTION_CLI_LIVE_OK")
print("model_ref="+x["model_ref"])
print("text="+x["text"])
PY

echo "=== 5. VERIFIED STT STATUS ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
refs=[ref for ref in r.all_discovered_refs() if "stt" in r.verified_capabilities(ref)]
assert refs,refs
print("verified_stt="+str(len(refs)),refs)
print("STT_STATUS_OK")
PY

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "stt-semantic-proof-v2",
  "functional_stt_proof": true,
  "numeric_normalization_accepted": true,
  "dedicated_transcription_cli": true,
  "central_jobs_audio_ingestion": false,
  "interfaz_voice_upload": false,
  "active": true
}
EOF

echo CENTRAL_STT_V2_READY
echo "backup=$BACKUP"
