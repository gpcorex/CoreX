#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STATE=/home/ubuntu/Central/state/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/capability-proof-v2-$STAMP

mkdir -p "$BACKUP"
for f in providers.py router.py capability_verify.py BUILD_REPORT.json; do
  [ -e "$DEST/$f" ] && cp -a "$DEST/$f" "$BACKUP/$f"
done

echo "=== 1. STRICT: FIXED MODELS MUST ALSO BE VERIFIED ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/router.py")
s=p.read_text(encoding="utf-8")
old='''    ranked_fixed=[]
    for c in fixed:
        declared=set(c.get("requirements") or [])
        # Fixed entries with no requirements are allowed for requirements-free tasks.
        if req and not set(req).issubset(declared):
            continue
        ranked_fixed.append(c)
'''
new='''    ranked_fixed=[]
    for c in fixed:
        declared=set(c.get("requirements") or [])
        # Declaring a requirement in the catalog is not proof that the model supports it.
        # Requirements-free tasks may use the fixed model normally; capability-bound
        # tasks require a functional PASS stored by Providers.
        if req:
            if not set(req).issubset(declared):
                continue
            if not set(req).issubset(registry.verified_capabilities(c["ref"])):
                continue
        ranked_fixed.append(c)
'''
if old not in s:
    raise SystemExit("FIXED_VERIFICATION_ANCHOR_NOT_FOUND")
p.write_text(s.replace(old,new,1),encoding="utf-8")
PY
python3 -m py_compile "$DEST/router.py"
echo FIXED_MODELS_REQUIRE_FUNCTIONAL_PROOF_OK

echo "=== 2. INSTALL CAPABILITY VERIFIER V2 ==="
cat >"$DEST/capability_verify.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, base64, json, struct, time, zlib
from config import load_settings
from providers import ProviderRegistry, groq_provider, openrouter_provider

STATE="/home/ubuntu/Central/state/providers.json"
REPORT="/home/ubuntu/Central/state/capability-verification.json"

def provider_for(ref,settings):
    p,m=ref.split("/",1)
    if p=="groq": return p,m,groq_provider(settings.groq_key,30)
    if p=="openrouter": return p,m,openrouter_provider(settings.openrouter_key,30)
    raise RuntimeError("UNSUPPORTED_PROVIDER:"+p)

def solid_red_png():
    w=h=64
    raw=b"".join(b"\x00"+b"\xff\x00\x00\xff"*w for _ in range(h))
    def chunk(t,d):
        return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
    png=b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",w,h,8,6,0,0,0))+chunk(b"IDAT",zlib.compress(raw))+chunk(b"IEND",b"")
    return "data:image/png;base64,"+base64.b64encode(png).decode()

def is_inconclusive_error(text):
    x=(text or "").lower()
    return any(k in x for k in (
        "429","rate limit","too many requests","tpm","itpm","tokens per minute",
        "temporarily","timeout","timed out","503","502"
    ))

def tools_probe(p,model):
    tools=[{"type":"function","function":{"name":"cap_test","description":"Capability test","parameters":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}}}]
    r=p.chat(model,[{"role":"user","content":"You must call the function cap_test exactly once with value TOOLS_OK. Do not answer with text."}],tools=tools,max_tokens=96,temperature=0)
    msg=((r.get("choices") or [{}])[0].get("message") or {})
    calls=msg.get("tool_calls") or []
    if not calls: return "FAIL","no_tool_call"
    try: args=json.loads(((calls[0].get("function") or {}).get("arguments")) or "{}")
    except Exception: return "FAIL","bad_tool_arguments"
    return ("PASS" if args.get("value")=="TOOLS_OK" else "FAIL"),"tool_call="+repr(args)

def json_probe(p,model):
    payload={
      "model":model,
      "messages":[{"role":"system","content":"Return valid JSON only."},{"role":"user","content":"Return exactly this object: {\"status\":\"JSON_OK\"}"}],
      "response_format":{"type":"json_object"},
      "max_tokens":96,
      "temperature":0,
    }
    try:
        r,_=p._request("/chat/completions",payload,"POST")
        content=((r.get("choices") or [{}])[0].get("message") or {}).get("content","")
        obj=json.loads(content)
        return ("PASS" if obj=={"status":"JSON_OK"} else "FAIL"),"json="+repr(obj)
    except Exception as e:
        t=str(e)
        return ("INCONCLUSIVE" if is_inconclusive_error(t) else "FAIL"),t[:240]

def vision_probe(p,model):
    payload={
      "model":model,
      "messages":[{"role":"user","content":[
        {"type":"text","text":"Inspect the image. If the image is solid red, reply exactly VISION_OK."},
        {"type":"image_url","image_url":{"url":solid_red_png()}}
      ]}],
      "max_tokens":48,
      "temperature":0,
    }
    try:
        r,_=p._request("/chat/completions",payload,"POST")
        ans=((r.get("choices") or [{}])[0].get("message") or {}).get("content","").strip()
        return ("PASS" if ans=="VISION_OK" else "FAIL"),"answer="+repr(ans)
    except Exception as e:
        t=str(e)
        return ("INCONCLUSIVE" if is_inconclusive_error(t) else "FAIL"),t[:240]

def context_probe(p,model):
    # ~3-4k input tokens: large enough to test retention while remaining under
    # the current free Groq per-minute ceilings. It is NOT proof of 100k+ context.
    filler=("abcdefghij "*900)
    prompt="BEGIN=ALFA-731\n"+filler+"\nEND=OMEGA-924\nReply exactly ALFA-731|OMEGA-924"
    try:
        r=p.chat(model,[{"role":"user","content":prompt}],max_tokens=48,temperature=0)
        ans=((r.get("choices") or [{}])[0].get("message") or {}).get("content","").strip()
        return ("PASS" if ans=="ALFA-731|OMEGA-924" else "FAIL"),"answer="+repr(ans)
    except Exception as e:
        t=str(e)
        return ("INCONCLUSIVE" if is_inconclusive_error(t) else "FAIL"),t[:240]

def candidates(reg,cap,maxn):
    capability={"tools":"programacion","json":"estructurado","vision":"vision","context_retention":"contexto_largo"}[cap]
    refs=[]
    for c in reg.get_fixed(capability):
        if c["ref"] not in refs: refs.append(c["ref"])
    metadata_req={"tools":"tools","json":"json","vision":"vision","context_retention":"long_context"}[cap]
    for ref in reg.all_discovered_refs():
        if ref in refs: continue
        provider,model=ref.split("/",1)
        if provider=="openrouter" and not (model.endswith(":free") or model=="free"): continue
        if metadata_req in reg.infer_metadata_capabilities(ref):
            refs.append(ref)
        if len(refs)>=maxn: break
    return refs[:maxn]

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--max-per-capability",type=int,default=3)
    ap.add_argument("--attempts",type=int,default=2)
    a=ap.parse_args()
    settings=load_settings()
    reg=ProviderRegistry(settings.groq_key,settings.openrouter_key,STATE)

    # Rebuild functional proof from scratch. No capability survives merely because
    # it was seeded or declared in metadata.
    reg.state["verified_capabilities"]={}
    reg.save()

    probes={
      "tools":tools_probe,
      "json":json_probe,
      "vision":vision_probe,
      "context_retention":context_probe,
    }
    results={}

    for cap,fn in probes.items():
        refs=candidates(reg,cap,a.max_per_capability)
        print(f"CAPABILITY {cap} candidates={len(refs)}")
        results[cap]=[]
        stored_cap={"tools":"tools","json":"json","vision":"vision","context_retention":"context_retention"}[cap]
        for ref in refs:
            _,model,p=provider_for(ref,settings)
            attempts=[]
            for n in range(a.attempts):
                try: status,detail=fn(p,model)
                except Exception as e:
                    t=str(e); status="INCONCLUSIVE" if is_inconclusive_error(t) else "FAIL"; detail=t[:240]
                attempts.append({"status":status,"detail":detail})
                if status=="PASS": break
                if status=="INCONCLUSIVE": time.sleep(1)
            final="PASS" if any(x["status"]=="PASS" for x in attempts) else ("INCONCLUSIVE" if any(x["status"]=="INCONCLUSIVE" for x in attempts) else "FAIL")
            print(ref,final,attempts[-1]["detail"])
            results[cap].append({"ref":ref,"status":final,"attempts":attempts})
            if final=="PASS":
                current=reg.verified_capabilities(ref)
                current.add(stored_cap)
                reg.set_verified_capabilities(ref,sorted(current))

    print("CAPABILITY audio SKIPPED reason=no_real_speech_fixture")
    with open(REPORT,"w",encoding="utf-8") as f:
        json.dump({
          "tested_at":int(time.time()),
          "results":results,
          "audio":{"status":"PENDING","reason":"no_real_speech_fixture"},
          "note":"context_retention PASS proves the tested moderate context only; it does not certify 100k+ context."
        },f,ensure_ascii=False,indent=2)
        f.write("\n")
    print("CAPABILITY_VERIFICATION_REPORT="+REPORT)

if __name__=="__main__":
    main()
PY
chmod 755 "$DEST/capability_verify.py"
python3 -m py_compile "$DEST/capability_verify.py"
echo CAPABILITY_VERIFIER_V2_INSTALLED

echo "=== 3. RUN REAL PROBES ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 "$DEST/capability_verify.py" --max-per-capability 3 --attempts 2
echo FUNCTIONAL_CAPABILITY_PROBES_V2_DONE

echo "=== 4. VERIFIED ROUTING COUNTS ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
from router import select
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
checks=[
  ("programacion","tools"),
  ("estructurado","json"),
  ("vision","vision"),
]
for cap,req in checks:
    xs=select(cap,r)
    verified=[x["ref"] for x in xs if req in r.verified_capabilities(x["ref"])]
    print(cap,"verified_routable="+str(len(verified)),verified[:8])
print("VERIFIED_ROUTING_COUNTS_OK")
PY

echo "=== 5. PROGRAMMING MUST STILL HAVE A VERIFIED MODEL ==="
sudo -u ubuntu PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import ProviderRegistry
from router import select
s=load_settings()
r=ProviderRegistry(s.groq_key,s.openrouter_key,"/home/ubuntu/Central/state/providers.json")
xs=select("programacion",r)
assert xs, "NO_VERIFIED_PROGRAMMING_MODEL"
assert "tools" in r.verified_capabilities(xs[0]["ref"])
print("VERIFIED_PROGRAMMING_ROUTE_OK",xs[0]["ref"])
PY

echo "=== 6. LIVE CENTRAL REGRESSION ==="
RESP=$(curl -fsS --max-time 5 -H 'Content-Type: application/json' \
  -d '{"task":"Creá capability-proof-v2.py que imprima exactamente CAPABILITY_PROOF_V2_OK, ejecutalo y verificá la salida.","source":"chat","project":"Central","conversation_id":"capability-proof-v2"}' \
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
print("CENTRAL_CAPABILITY_PROOF_V2_REGRESSION_OK")
PY

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "capability-proof-v2",
  "functional_proof_required_for_fixed_and_dynamic": true,
  "transient_failures": "inconclusive_or_retried",
  "vision_fixture": "64x64-real-png",
  "context_test": "moderate-retention-not-max-context",
  "audio_stt": "pending-real-speech-fixture",
  "active": true
}
EOF

echo CENTRAL_CAPABILITY_PROOF_V2_READY
echo "report=/home/ubuntu/Central/state/capability-verification.json"
echo "backup=$BACKUP"
