#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STATE=/home/ubuntu/Central/state/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/capability-functional-verifier-$STAMP

mkdir -p "$BACKUP"
for f in providers.py router.py BUILD_REPORT.json; do
  [ -e "$DEST/$f" ] && cp -a "$DEST/$f" "$BACKUP/$f"
done

echo "=== 1. INSTALL FUNCTIONAL CAPABILITY VERIFIER ==="
cat >"$DEST/capability_verify.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, base64, json, struct, zlib
from config import load_settings
from providers import ProviderRegistry, groq_provider, openrouter_provider

STATE="/home/ubuntu/Central/state/providers.json"

def provider_for(ref,settings):
    p,m=ref.split("/",1)
    if p=="groq": return p,m,groq_provider(settings.groq_key,30)
    if p=="openrouter": return p,m,openrouter_provider(settings.openrouter_key,30)
    raise RuntimeError("UNSUPPORTED_PROVIDER:"+p)

def tiny_red_png_data_url():
    # 8x8 opaque red PNG, generated with stdlib only.
    w=h=8
    raw=b"".join(b"\x00"+b"\xff\x00\x00\xff"*w for _ in range(h))
    def chunk(t,d):
        return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
    png=b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",w,h,8,6,0,0,0))+chunk(b"IDAT",zlib.compress(raw))+chunk(b"IEND",b"")
    return "data:image/png;base64,"+base64.b64encode(png).decode()

def verify_tools(p,model):
    tools=[{"type":"function","function":{"name":"cap_test","description":"Capability test","parameters":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}}}]
    r=p.chat(model,[{"role":"user","content":"Call cap_test with value exactly TOOLS_OK. Do not answer normally."}],tools=tools,max_tokens=80,temperature=0)
    msg=((r.get("choices") or [{}])[0].get("message") or {})
    calls=msg.get("tool_calls") or []
    if not calls: return False,"no_tool_call"
    fn=(calls[0].get("function") or {})
    try: args=json.loads(fn.get("arguments") or "{}")
    except Exception: return False,"bad_tool_arguments"
    return args.get("value")=="TOOLS_OK","tool_call="+str(args)

def verify_json(p,model):
    payload={
      "model":model,
      "messages":[{"role":"user","content":"Return JSON with exactly one key named status and value JSON_OK."}],
      "response_format":{"type":"json_object"},
      "max_tokens":80,
      "temperature":0,
    }
    try:
        r,_=p._request("/chat/completions",payload,"POST")
        content=((r.get("choices") or [{}])[0].get("message") or {}).get("content","")
        obj=json.loads(content)
        return obj=={"status":"JSON_OK"},"json="+repr(obj)
    except Exception as e:
        return False,str(e)[:220]

def verify_vision(p,model):
    payload={
      "model":model,
      "messages":[{"role":"user","content":[
        {"type":"text","text":"The image is a solid color. If it is red, reply exactly VISION_OK. Otherwise reply VISION_FAIL."},
        {"type":"image_url","image_url":{"url":tiny_red_png_data_url()}}
      ]}],
      "max_tokens":40,
      "temperature":0,
    }
    try:
        r,_=p._request("/chat/completions",payload,"POST")
        ans=((r.get("choices") or [{}])[0].get("message") or {}).get("content","").strip()
        return ans=="VISION_OK","answer="+repr(ans)
    except Exception as e:
        return False,str(e)[:220]

def verify_long_context(p,model):
    # Functional retention test, deliberately moderate to avoid burning free TPM.
    # This verifies long-context behavior at ~24k chars, not the provider's absolute max.
    middle=("abcdefghij "*2200)
    prompt="BEGIN_SENTINEL=ALFA-731\n"+middle+"\nEND_SENTINEL=OMEGA-924\nReply exactly ALFA-731|OMEGA-924"
    try:
        r=p.chat(model,[{"role":"user","content":prompt}],max_tokens=40,temperature=0)
        ans=((r.get("choices") or [{}])[0].get("message") or {}).get("content","").strip()
        return ans=="ALFA-731|OMEGA-924","answer="+repr(ans)
    except Exception as e:
        return False,str(e)[:220]

def candidate_refs(registry,cap,maxn):
    req={"tools":"tools","json":"json","vision":"vision","long_context":"long_context"}[cap]
    refs=[]
    # Fixed first.
    capability={"tools":"programacion","json":"estructurado","vision":"vision","long_context":"contexto_largo"}[cap]
    for c in registry.get_fixed(capability):
        if c["ref"] not in refs: refs.append(c["ref"])
    # Then provider-metadata candidates.
    for ref in registry.all_discovered_refs():
        if ref in refs: continue
        provider,model=ref.split("/",1)
        if provider=="openrouter" and not (model.endswith(":free") or model=="free"): continue
        if req in registry.infer_metadata_capabilities(ref):
            refs.append(ref)
        if len(refs)>=maxn: break
    return refs[:maxn]

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--max-per-capability",type=int,default=3)
    a=ap.parse_args()

    settings=load_settings()
    reg=ProviderRegistry(settings.groq_key,settings.openrouter_key,STATE)
    results={}
    funcs={"tools":verify_tools,"json":verify_json,"vision":verify_vision,"long_context":verify_long_context}

    for cap,fn in funcs.items():
        results[cap]=[]
        refs=candidate_refs(reg,cap,a.max_per_capability)
        print(f"CAPABILITY {cap} candidates={len(refs)}")
        for ref in refs:
            provider,model,p=provider_for(ref,settings)
            ok=False; detail=""
            try: ok,detail=fn(p,model)
            except Exception as e: detail=str(e)[:220]
            print(ref,"PASS" if ok else "FAIL",detail)
            results[cap].append({"ref":ref,"ok":ok,"detail":detail})
            if ok:
                current=reg.verified_capabilities(ref)
                current.add(cap)
                reg.set_verified_capabilities(ref,sorted(current))

    # Audio/STT intentionally remains unverified until an actual speech sample is tested.
    print("CAPABILITY audio SKIPPED reason=no_real_speech_fixture")

    out="/home/ubuntu/Central/state/capability-verification.json"
    with open(out,"w",encoding="utf-8") as f:
        json.dump({"results":results,"audio":{"verified":False,"reason":"no_real_speech_fixture"}},f,ensure_ascii=False,indent=2)
        f.write("\n")
    print("CAPABILITY_VERIFICATION_REPORT="+out)

if __name__=="__main__":
    main()
PY
chmod 755 "$DEST/capability_verify.py"
python3 -m py_compile "$DEST/capability_verify.py"
echo CAPABILITY_VERIFIER_INSTALLED

echo "=== 2. CLEAR UNPROVEN NONCORE CAPABILITIES ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
# Keep only capabilities proven earlier by real programming/tool runs.
for ref in list((r.state.get("verified_capabilities") or {}).keys()):
    keep=r.verified_capabilities(ref) & {"tools","json"}
    r.set_verified_capabilities(ref,sorted(keep))
print("UNPROVEN_CAPABILITIES_CLEARED")
PY

echo "=== 3. RUN FUNCTIONAL VERIFICATION ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 "$DEST/capability_verify.py" --max-per-capability 3
echo FUNCTIONAL_CAPABILITY_PROBES_DONE

echo "=== 4. SHOW ROUTABLE COUNTS AFTER REAL VERIFICATION ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
from router import select
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
for cap in ("programacion","estructurado","vision","voz","contexto_largo"):
    xs=select(cap,r)
    verified=[]
    req={"programacion":"tools","estructurado":"json","vision":"vision","voz":"audio","contexto_largo":"long_context"}[cap]
    for x in xs:
        if req in r.verified_capabilities(x["ref"]):
            verified.append(x["ref"])
    print(cap,"verified_routable="+str(len(verified)),verified[:5])
print("ROUTABLE_VERIFIED_COUNTS_OK")
PY

echo "=== 5. PROGRAMMING REGRESSION ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá capability-real-proof.py que imprima exactamente CAPABILITY_REAL_PROOF_OK, ejecutalo y verificá la salida.","source":"chat","project":"Central","conversation_id":"capability-real-proof"}' \
  http://127.0.0.1:8091/api/jobs)
JOB=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$RESP")
for i in $(seq 1 120); do
  OUT=$(curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB")
  S=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["status"])' <<<"$OUT")
  printf '\rstatus=%s elapsed=%ss' "$S" "$i"
  case "$S" in COMPLETADA|ERROR) break;; esac
  sleep 1
done
echo
OUT_JSON="$OUT" python3 - <<'PY'
import json,os
j=json.loads(os.environ["OUT_JSON"])["job"]
assert j["status"]=="COMPLETADA",j
assert (j.get("result") or {}).get("jugador")=="Central Native",j
print("CENTRAL_CAPABILITY_REAL_PROOF_REGRESSION_OK")
PY

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "functional-capability-verifier",
  "capability_verification": "functional",
  "audio_stt": "pending-real-speech-fixture",
  "periodic_refresh": false,
  "active": true
}
EOF

echo CENTRAL_FUNCTIONAL_CAPABILITY_VERIFIER_READY
echo "report=/home/ubuntu/Central/state/capability-verification.json"
echo "backup=$BACKUP"
