#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/voice-stt-v1-$STAMP

mkdir -p "$BACKUP"
for f in providers.py router.py BUILD_REPORT.json; do
  [ -e "$DEST/$f" ] && cp -a "$DEST/$f" "$BACKUP/$f"
done

echo "=== 1. ENSURE LOCAL SPEECH FIXTURE GENERATOR ==="
if command -v espeak-ng >/dev/null 2>&1; then
  TTS=$(command -v espeak-ng)
elif command -v espeak >/dev/null 2>&1; then
  TTS=$(command -v espeak)
else
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq espeak-ng
  TTS=$(command -v espeak-ng)
fi
echo "TTS_FIXTURE_GENERATOR=$TTS"

FIX=/tmp/central-stt-proof.wav
"$TTS" -w "$FIX" -s 135 -v en-us "central voice test seven three one"
test -s "$FIX"
file "$FIX" || true
echo SPEECH_FIXTURE_READY

echo "=== 2. INSTALL REAL GROQ STT VERIFIER ==="
cat >"$DEST/voice_stt_verify.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import json, os, re, subprocess, tempfile
from config import load_settings
from providers import ProviderRegistry

STATE="/home/ubuntu/Central/state/providers.json"
MODELS=("whisper-large-v3-turbo","whisper-large-v3")
EXPECTED=("central","voice","test","seven","three","one")

def norm(s):
    return re.sub(r"[^a-z0-9 ]+"," ",(s or "").lower()).split()

def transcribe(key,model,path):
    cmd=[
      "curl","-fsS","--max-time","60",
      "-H",f"Authorization: Bearer {key}",
      "-F",f"file=@{path}",
      "-F",f"model={model}",
      "-F","response_format=json",
      "https://api.groq.com/openai/v1/audio/transcriptions",
    ]
    cp=subprocess.run(cmd,text=True,capture_output=True)
    if cp.returncode!=0:
        return False,"curl:"+cp.stderr.strip()[:240],None
    try:
        obj=json.loads(cp.stdout)
    except Exception:
        return False,"non_json:"+cp.stdout[:240],None
    text=obj.get("text","")
    words=norm(text)
    ok=all(x in words for x in EXPECTED)
    return ok,text,obj

def main():
    import argparse
    ap=argparse.ArgumentParser()
    ap.add_argument("audio")
    args=ap.parse_args()

    s=load_settings()
    if not s.groq_key:
        raise SystemExit("NO_GROQ_KEY")

    reg=ProviderRegistry(s.groq_key,s.openrouter_key,STATE)
    results=[]
    for model in MODELS:
        ref="groq/"+model
        ok,detail,obj=transcribe(s.groq_key,model,args.audio)
        print(ref,"PASS" if ok else "FAIL",repr(detail))
        results.append({"ref":ref,"ok":ok,"transcript":detail})
        if ok:
            caps=reg.verified_capabilities(ref)
            caps.add("stt")
            reg.set_verified_capabilities(ref,sorted(caps))

    out="/home/ubuntu/Central/state/stt-verification.json"
    with open(out,"w",encoding="utf-8") as f:
        json.dump({"audio_fixture":os.path.basename(args.audio),"results":results},f,ensure_ascii=False,indent=2)
        f.write("\n")

    if not any(x["ok"] for x in results):
        raise SystemExit("NO_STT_MODEL_VERIFIED")
    print("STT_FUNCTIONAL_PROOF_OK")
    print("report="+out)

if __name__=="__main__":
    main()
PY
chmod 755 "$DEST/voice_stt_verify.py"
python3 -m py_compile "$DEST/voice_stt_verify.py"
echo STT_VERIFIER_INSTALLED

echo "=== 3. FUNCTIONAL STT PROOF ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 "$DEST/voice_stt_verify.py" "$FIX"

echo "=== 4. INSTALL DEDICATED TRANSCRIPTION CLI ==="
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
    candidates=[]
    for ref in r.all_discovered_refs():
        if "stt" in r.verified_capabilities(ref):
            candidates.append(ref)
    if not candidates:
        raise SystemExit("NO_VERIFIED_STT_ROUTE")

    # Prefer turbo when both have functional proof.
    candidates.sort(key=lambda x:(0 if x.endswith("whisper-large-v3-turbo") else 1,x))
    ref=candidates[0]
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

echo "=== 5. LIVE TRANSCRIPTION CLI TEST ==="
OUT=$(sudo -u ubuntu PYTHONPATH="$DEST" python3 "$DEST/transcribe.py" "$FIX")
echo "$OUT"
OUT_JSON="$OUT" python3 - <<'PY'
import json,os,re
x=json.loads(os.environ["OUT_JSON"])
assert x["ok"] is True,x
assert x["capability"]=="stt",x
words=re.sub(r"[^a-z0-9 ]+"," ",x["text"].lower()).split()
for w in ("central","voice","test","seven","three","one"):
    assert w in words,(w,x)
print("TRANSCRIPTION_CLI_LIVE_OK")
print("model_ref="+x["model_ref"])
print("text="+x["text"])
PY

echo "=== 6. VOICE CAPABILITY STATUS ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
refs=[ref for ref in r.all_discovered_refs() if "stt" in r.verified_capabilities(ref)]
print("verified_stt="+str(len(refs)),refs)
assert refs
print("STT_STATUS_OK")
PY

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "voice-stt-v1",
  "functional_stt_proof": true,
  "dedicated_transcription_cli": true,
  "central_jobs_audio_ingestion": false,
  "interfaz_voice_upload": false,
  "active": true
}
EOF

echo CENTRAL_STT_V1_READY
echo "NOTE=STT provider capability is now functionally verified; attachment/voice ingestion into Central Jobs is the next layer."
echo "backup=$BACKUP"
