#!/usr/bin/env bash
set -euo pipefail

CFG=/home/ubuntu/Gemini/config/providers.json
OUT=/home/ubuntu/Gemini/config/providers.disabled.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/provider-audit-curl-$STAMP
mkdir -p "$BACKUP"
cp -a "$CFG" "$BACKUP/providers.json"

python3 - <<'PY'
import json, subprocess
from pathlib import Path

CFG=Path("/home/ubuntu/Gemini/config/providers.json")
OUT=Path("/home/ubuntu/Gemini/config/providers.disabled.json")
data=json.loads(CFG.read_text())
providers=data.get("providers", [])

def keyfiles(pid, configured):
    out=[]; seen=set()
    for s in [configured]:
        if s and s not in seen:
            seen.add(s); out.append(s)
    for root in [Path("/home/ubuntu/Claves/providers"),Path("/home/ubuntu/Claves")]:
        if root.exists():
            for p in root.rglob("*"):
                if p.is_file() and pid.lower() in p.name.lower():
                    s=str(p)
                    if s not in seen:
                        seen.add(s); out.append(s)
    return out

def readkey(p):
    try: return Path(p).read_text().strip()
    except: return ""

def curl_json(url,key,payload=None,extra=None):
    cmd=["curl","-sS","--max-time","25","-o","/tmp/provider-audit-body","-w","%{http_code}"]
    cmd += ["-H",f"Authorization: Bearer {key}","-H","Content-Type: application/json"]
    for h in (extra or []):
        cmd += ["-H",h]
    if payload is not None:
        cmd += ["-X","POST","--data",json.dumps(payload)]
    cmd += [url]
    p=subprocess.run(cmd,text=True,capture_output=True)
    body=""
    try: body=Path("/tmp/provider-audit-body").read_text(errors="replace")
    except: pass
    code=p.stdout.strip()
    if p.returncode != 0:
        return 0, body, p.stderr.strip()
    try: code=int(code)
    except: code=0
    return code, body, ""

def test_provider(pr,key):
    pid=str(pr.get("id") or "").lower()
    base=str(pr.get("base_url") or "").rstrip("/")
    extra=[]
    if pid=="openrouter":
        extra=["HTTP-Referer: http://127.0.0.1","X-Title: Central"]
        code,body,err=curl_json(base+"/models",key,None,extra)
        if code==0: return False,"NETWORK:"+err[:120],None,True
        if code in (401,403): return False,f"AUTH_{code}",None,False
        if code>=400: return False,f"MODELS_HTTP_{code}",None,False
        model="openrouter/free"
        try:
            arr=json.loads(body).get("data") or []
            free=[]
            for x in arr:
                mid=str(x.get("id") or "")
                pricing=x.get("pricing") or {}
                pp=str(pricing.get("prompt",""))
                cp=str(pricing.get("completion",""))
                if mid.endswith(":free") or (pp in {"0","0.0","0.000000"} and cp in {"0","0.0","0.000000"}):
                    free.append(mid)
            if free: model=free[0]
        except: pass
    else:
        model=str(pr.get("model") or "")
    payload={"model":model,"messages":[{"role":"user","content":"Reply only OK"}],"temperature":0,"max_tokens":8}
    code,body,err=curl_json(base+"/chat/completions",key,payload,extra)
    if code==0: return False,"NETWORK:"+err[:120],model,True
    if code in (401,403): return False,f"AUTH_{code}",model,False
    if code==429: return False,"RATE_LIMIT_429",model,False
    if code>=400: return False,f"HTTP_{code}",model,False
    try:
        j=json.loads(body); ch=j.get("choices") or []
        txt=((ch[0].get("message") or {}).get("content") if ch else "") or ""
        if not str(txt).strip(): return False,"EMPTY_RESPONSE",model,False
    except Exception:
        return False,"BAD_JSON",model,False
    return True,"OK",model,False

working=[]; disabled=[]; transient=[]
for pr in providers:
    pid=str(pr.get("id") or pr.get("name") or "").lower()
    if pid=="gemini":
        disabled.append({"id":pid,"reason":"BANNED"})
        continue
    configured=str(pr.get("key_file") or "")
    passed=False; last=("NO_KEY",None,False); used=None
    for kf in keyfiles(pid,configured):
        key=readkey(kf)
        if not key: continue
        ok,reason,model,is_transient=test_provider(pr,key)
        last=(reason,model,is_transient)
        if ok:
            passed=True; used=kf
            if used != configured: pr["key_file"]=used
            print(f"PASS {pid} model={model} keyfile={used}")
            break
    if passed:
        working.append(pr)
    else:
        reason,model,is_transient=last
        print(f"FAIL {pid} reason={reason} model={model}")
        if is_transient:
            transient.append({"id":pid,"reason":reason})
            working.append(pr)
        else:
            disabled.append({"id":pid,"reason":reason})

if working:
    data["providers"]=working
    CFG.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n")
else:
    print("NO_PROVIDER_PASSED_OR_TRANSIENT_CONFIG_UNCHANGED")

OUT.write_text(json.dumps({"disabled":disabled,"transient":transient},ensure_ascii=False,indent=2)+"\n")
print("ACTIVE=", [p.get("id") or p.get("name") for p in working])
print("DISABLED=", disabled)
print("TRANSIENT=", transient)
PY

systemctl restart gemini-backend.service
for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/provider-audit2-health.json 2>/dev/null && break
  sleep 1
done

echo "=== HEALTH ==="; cat /tmp/provider-audit2-health.json; echo
echo "=== ACTIVE PROVIDERS ==="; curl -sS --max-time 5 http://127.0.0.1:8791/api/providers; echo
echo "=== DISABLED/TRANSIENT ==="; cat "$OUT"; echo
echo PROVIDER_CURL_AUDIT_READY
