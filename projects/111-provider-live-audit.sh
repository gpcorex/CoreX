#!/usr/bin/env bash
set -euo pipefail

CFG=/home/ubuntu/Gemini/config/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/provider-audit-$STAMP
mkdir -p "$BACKUP"
cp -a "$CFG" "$BACKUP/providers.json"

python3 - <<'PY'
import json, os, ssl, urllib.request, urllib.error
from pathlib import Path

CFG=Path("/home/ubuntu/Gemini/config/providers.json")
data=json.loads(CFG.read_text(encoding="utf-8"))
providers=data.get("providers", [])

def read_key(path):
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except Exception:
        return ""

def request_json(url, method="GET", headers=None, payload=None, timeout=20):
    body=None if payload is None else json.dumps(payload).encode()
    req=urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ssl.create_default_context()) as r:
            raw=r.read().decode("utf-8","replace")
            return r.status, raw
    except urllib.error.HTTPError as e:
        raw=e.read().decode("utf-8","replace")
        return e.code, raw
    except Exception as e:
        return 0, type(e).__name__ + ":" + str(e)

def candidate_key_files(pid, configured):
    seen=set()
    out=[]
    for p in [configured]:
        if p and p not in seen:
            seen.add(p); out.append(p)
    roots=[Path("/home/ubuntu/Claves/providers"), Path("/home/ubuntu/Claves")]
    for root in roots:
        if root.exists():
            for p in root.rglob("*"):
                if p.is_file() and pid.lower() in p.name.lower():
                    s=str(p)
                    if s not in seen:
                        seen.add(s); out.append(s)
    return out

def test_openai_compatible(p, key):
    base=str(p.get("base_url","")).rstrip("/")
    pid=str(p.get("id",""))
    headers={"Authorization":f"Bearer {key}","Content-Type":"application/json"}
    if pid=="openrouter":
        headers["HTTP-Referer"]="http://127.0.0.1"
        headers["X-Title"]="Parallel Assistant"
        st,raw=request_json(base+"/models",headers=headers,timeout=20)
        if st in (401,403) or st==0 or st>=500:
            return False, f"models_http_{st}", None
        model=None
        if st<400:
            try:
                arr=json.loads(raw).get("data") or []
                free=[]
                for x in arr:
                    mid=str(x.get("id") or "")
                    pricing=x.get("pricing") or {}
                    pp=str(pricing.get("prompt",""))
                    cp=str(pricing.get("completion",""))
                    if mid.endswith(":free") or (pp in {"0","0.0","0.000000"} and cp in {"0","0.0","0.000000"}):
                        free.append(mid)
                if free:
                    model=free[0]
            except Exception:
                pass
        model=model or "openrouter/free"
    else:
        model=str(p.get("model") or "")
    payload={"model":model,"messages":[{"role":"user","content":"Reply only OK"}],"temperature":0,"max_tokens":8}
    st,raw=request_json(base+"/chat/completions","POST",headers,payload,30)
    if st in (401,403): return False, f"auth_http_{st}", model
    if st==429: return False, "rate_limit_429", model
    if st==0 or st>=500: return False, f"http_{st}", model
    if st>=400: return False, f"http_{st}", model
    try:
        j=json.loads(raw)
        choices=j.get("choices") or []
        txt=((choices[0].get("message") or {}).get("content") if choices else "") or ""
        if not str(txt).strip():
            return False, "empty_response", model
    except Exception:
        return False, "bad_json", model
    return True, "ok", model

working=[]
failed=[]
for p in providers:
    pid=str(p.get("id") or p.get("name") or "").strip().lower()
    ptype=str(p.get("type") or "openai").strip().lower()
    if pid=="gemini" or ptype in {"gemini","google_gemini"}:
        failed.append((pid,"gemini_banned"))
        continue
    configured=str(p.get("key_file") or "")
    success=False
    last_reason="no_key"
    used_file=None
    used_model=None
    for kf in candidate_key_files(pid, configured):
        key=read_key(kf)
        if not key:
            last_reason="empty_key"
            continue
        if ptype in {"openai","openai_compatible","openrouter","groq"} or p.get("base_url"):
            ok,reason,model=test_openai_compatible(p,key)
        else:
            ok,reason,model=False,"unsupported_type",None
        last_reason=reason
        used_model=model
        if ok:
            success=True
            used_file=kf
            break
    if success:
        if used_file and used_file != configured:
            p["key_file"]=used_file
        working.append(p)
        print(f"PASS {pid} model={used_model or p.get('model')} keyfile={used_file}")
    else:
        failed.append((pid,last_reason))
        print(f"FAIL {pid} reason={last_reason}")

if not working:
    print("NO_WORKING_PROVIDERS_CONFIG_UNCHANGED")
    raise SystemExit(2)

data["providers"]=working
CFG.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
Path("/home/ubuntu/Gemini/config/providers.disabled.json").write_text(
    json.dumps({"disabled":[{"id":i,"reason":r} for i,r in failed]},ensure_ascii=False,indent=2)+"\n",
    encoding="utf-8"
)
print("ACTIVE=", [p.get("id") or p.get("name") for p in working])
print("DISABLED=", failed)
PY

systemctl restart gemini-backend.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/provider-audit-health.json 2>/dev/null; then break; fi
  sleep 1
done

echo "=== HEALTH ==="
cat /tmp/provider-audit-health.json
echo
echo "=== ACTIVE PROVIDERS ==="
curl -fsS --max-time 5 http://127.0.0.1:8791/api/providers
echo
echo "=== DISABLED ==="
cat /home/ubuntu/Gemini/config/providers.disabled.json 2>/dev/null || true
echo
echo PROVIDER_LIVE_AUDIT_READY
