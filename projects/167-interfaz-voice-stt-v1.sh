#!/usr/bin/env bash
set -euo pipefail

APP=/home/ubuntu/Interfaz
SERVER="$APP/server.py"
NATIVE=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/interfaz-voice-v1-$STAMP

mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. PATCH INTERFAZ BACKEND: /api/transcribe ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

# imports
old='import json, os, re, sqlite3, time, urllib.request, urllib.error, uuid'
new='import base64, json, os, re, sqlite3, subprocess, tempfile, time, urllib.request, urllib.error, uuid'
if old in s:
    s=s.replace(old,new,1)
elif 'import base64' not in s:
    raise SystemExit("IMPORT_ANCHOR_NOT_FOUND")

# endpoint before /api/message
anchor='''        if p=="/api/message":
            try:
'''
insert='''        if p=="/api/transcribe":
            try:
                b=self.read_json()
                raw=str(b.get("audio_base64") or "")
                if not raw:
                    return self.send_json(400,{"ok":False,"error":"AUDIO_REQUIRED"})
                if "," in raw:
                    raw=raw.split(",",1)[1]
                audio=base64.b64decode(raw,validate=True)
                if not audio or len(audio)>20*1024*1024:
                    return self.send_json(400,{"ok":False,"error":"AUDIO_SIZE_INVALID"})
                suffix=str(b.get("suffix") or ".webm")
                if not re.fullmatch(r"\.[a-zA-Z0-9]{2,5}",suffix):
                    suffix=".webm"
                fd,path=tempfile.mkstemp(prefix="interfaz-voice-",suffix=suffix)
                try:
                    with os.fdopen(fd,"wb") as f:
                        f.write(audio)
                    env=dict(os.environ)
                    env["PYTHONPATH"]="/home/ubuntu/Central/native_v1"
                    cp=subprocess.run(
                        ["/usr/bin/python3","/home/ubuntu/Central/native_v1/transcribe.py",path],
                        text=True,capture_output=True,timeout=120,env=env
                    )
                    if cp.returncode!=0:
                        return self.send_json(502,{"ok":False,"error":"STT_FAILED","detail":(cp.stderr or cp.stdout)[-800:]})
                    out=json.loads(cp.stdout)
                    return self.send_json(200,{
                        "ok":True,
                        "text":str(out.get("text") or "").strip(),
                        "model_ref":out.get("model_ref"),
                        "capability":"stt"
                    })
                finally:
                    try: os.unlink(path)
                    except Exception: pass
            except Exception as e:
                return self.send_json(500,{"ok":False,"error":"TRANSCRIBE_FAILED","detail":str(e)})
        if p=="/api/message":
            try:
'''
if '/api/transcribe' not in s:
    if anchor not in s:
        raise SystemExit("TRANSCRIBE_ENDPOINT_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert,1)

# CSS for mic button
oldcss='.send{width:44px;height:44px;border:0;border-radius:50%;background:var(--accent);color:#111;font-size:20px}'
newcss='.send,.mic{width:44px;height:44px;border:0;border-radius:50%;font-size:20px}.send{background:var(--accent);color:#111}.mic{background:transparent;color:var(--text);border:1px solid var(--line)}.mic.recording{background:#a33;color:#fff;border-color:#a33}'
if oldcss in s:
    s=s.replace(oldcss,newcss,1)

# mic button in composer
oldhtml='''   <textarea id="input" rows="1" placeholder="Escribí un mensaje..."></textarea>
   <button class="send" id="send">➤</button>
'''
newhtml='''   <textarea id="input" rows="1" placeholder="Escribí un mensaje..."></textarea>
   <button class="mic" id="mic" title="Hablar">🎙</button>
   <button class="send" id="send">➤</button>
'''
if 'id="mic"' not in s:
    if oldhtml not in s:
        raise SystemExit("MIC_HTML_ANCHOR_NOT_FOUND")
    s=s.replace(oldhtml,newhtml,1)

# JS helper + recorder
anchorjs='''async function send(){
 const t=$('#input').value.trim(); if(!t)return
'''
voicejs=r'''let mediaRecorder=null,mediaChunks=[];
async function toggleMic(){
 const b=$('#mic');
 if(mediaRecorder&&mediaRecorder.state==='recording'){
   mediaRecorder.stop(); return
 }
 try{
   const stream=await navigator.mediaDevices.getUserMedia({audio:true});
   mediaChunks=[];
   mediaRecorder=new MediaRecorder(stream);
   mediaRecorder.ondataavailable=e=>{if(e.data&&e.data.size)mediaChunks.push(e.data)}
   mediaRecorder.onstop=async()=>{
     b.classList.remove('recording'); b.textContent='🎙';
     stream.getTracks().forEach(t=>t.stop());
     try{
       const blob=new Blob(mediaChunks,{type:mediaRecorder.mimeType||'audio/webm'});
       const data=await new Promise((resolve,reject)=>{
         const r=new FileReader();r.onload=()=>resolve(r.result);r.onerror=reject;r.readAsDataURL(blob)
       });
       b.disabled=true;
       const x=await api('api/transcribe',{
         method:'POST',
         headers:{'Content-Type':'application/json'},
         body:JSON.stringify({audio_base64:data,suffix:'.webm'})
       });
       $('#input').value=(x.text||'').trim();
       resize(); $('#input').focus();
     }catch(e){addMsg('assistant','Error de voz: '+e.message)}
     finally{b.disabled=false;mediaRecorder=null}
   };
   mediaRecorder.start();
   b.classList.add('recording'); b.textContent='■';
 }catch(e){addMsg('assistant','No pude acceder al micrófono: '+e.message)}
}
async function send(){
 const t=$('#input').value.trim(); if(!t)return
'''
if 'async function toggleMic()' not in s:
    if anchorjs not in s:
        raise SystemExit("MIC_JS_ANCHOR_NOT_FOUND")
    s=s.replace(anchorjs,voicejs,1)

clickanchor="$('#send').onclick=send;"
if "$('#mic').onclick=toggleMic;" not in s:
    if clickanchor not in s:
        raise SystemExit("MIC_CLICK_ANCHOR_NOT_FOUND")
    s=s.replace(clickanchor,"$('#mic').onclick=toggleMic;"+clickanchor,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo INTERFAZ_VOICE_BACKEND_UI_PATCH_OK

echo "=== 2. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/interfaz-voice-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/interfaz-voice-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_RESTART_OK

echo "=== 3. API TRANSCRIPTION TEST WITH VERIFIED WAV ==="
FIX=/tmp/central-stt-proof.wav
test -s "$FIX" || espeak-ng -w "$FIX" -s 135 -v en-us "central voice test seven three one"
B64=$(base64 -w0 "$FIX")
OUT=$(curl -fsS --max-time 120 -H 'Content-Type: application/json'   -d "{\"audio_base64\":\"$B64\",\"suffix\":\".wav\"}"   http://127.0.0.1:8791/api/transcribe)
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

echo "=== 4. PUBLIC INTERFAZ CHECK ==="
curl -fsS --max-time 15 https://cen-tral.duckdns.org/interfaz/ | grep -q 'id="mic"'
echo INTERFAZ_MIC_PUBLIC_OK

cat >"$NATIVE/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "interfaz-voice-v1",
  "stt_verified_models": 2,
  "interfaz_transcribe_endpoint": true,
  "browser_microphone": true,
  "voice_to_text": true,
  "auto_send_after_transcription": false,
  "active": true
}
EOF

echo CENTRAL_INTERFAZ_VOICE_V1_READY
echo "URL=https://cen-tral.duckdns.org/interfaz/"
echo "NOTE=Mic transcribes into the composer; user reviews text and presses send."
echo "backup=$BACKUP"
