#!/usr/bin/env bash
set -euo pipefail

CFG=/home/ubuntu/Gemini/config/providers.json
OUT=/home/ubuntu/Gemini/config/providers.disabled.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/provider-httpx-audit-$STAMP
mkdir -p "$BACKUP"
cp -a "$CFG" "$BACKUP/providers.json"

PYTHON=/usr/bin/python3
if [ -x /home/ubuntu/Gemini/.venv/bin/python ]; then
  PYTHON=/home/ubuntu/Gemini/.venv/bin/python
fi

"$PYTHON" - <<'PY'
import asyncio, json
from pathlib import Path
import httpx

CFG=Path("/home/ubuntu/Gemini/config/providers.json")
OUT=Path("/home/ubuntu/Gemini/config/providers.disabled.json")
data=json.loads(CFG.read_text(encoding="utf-8"))
providers=data.get("providers", [])

def read_key(path):
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except Exception:
        return ""

def candidates(pid, configured):
    out=[]; seen=set()
    for p in [configured]:
        if p and p not in seen:
            seen.add(p); out.append(p)
    for root in [Path("/home/ubuntu/Claves/providers"), Path("/home/ubuntu/Claves")]:
        if not root.exists():
            continue
        for p in root.rglob("*"):
            if p.is_file() and pid.lower() in p.name.lower():
                s=str(p)
                if s not in seen:
                    seen.add(s); out.append(s)
    return out

async def test(pr,key):
    pid=str(pr.get("id") or "").lower()
    base=str(pr.get("base_url") or "").rstrip("/")
    headers={"Authorization":f"Bearer {key}","Content-Type":"application/json"}
    if pid=="openrouter":
        headers["HTTP-Referer"]="http://127.0.0.1"
        headers["X-Title"]="Central"
        try:
            async with httpx.AsyncClient(timeout=20.0) as c:
                r=await c.get(base+"/models",headers=headers)
        except Exception as e:
            return False, "NETWORK_"+type(e).__name__, None, True
        if r.status_code in (401,403):
            return False, f"AUTH_{r.status_code}", None, False
        if r.status_code >= 400:
            return False, f"MODELS_HTTP_{r.status_code}", None, False
        model="openrouter/free"
        try:
            arr=r.json().get("data") or []
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
    else:
        model=str(pr.get("model") or "")

    payload={
        "model":model,
        "messages":[{"role":"user","content":"Reply only OK"}],
        "temperature":0,
        "max_tokens":8
    }
    try:
        async with httpx.AsyncClient(timeout=30.0) as c:
            r=await c.post(base+"/chat/completions",headers=headers,json=payload)
    except Exception as e:
        return False, "NETWORK_"+type(e).__name__, model, True

    if r.status_code in (401,403):
        return False, f"AUTH_{r.status_code}", model, False
    if r.status_code == 429:
        return False, "RATE_LIMIT_429", model, False
    if r.status_code >= 400:
        return False, f"HTTP_{r.status_code}", model, False

    try:
        j=r.json()
        choices=j.get("choices") or []
        txt=((choices[0].get("message") or {}).get("content") if choices else "") or ""
        if not str(txt).strip():
            return False, "EMPTY_RESPONSE", model, False
    except Exception:
        return False, "BAD_JSON", model, False

    return True, "OK", model, False

async def main():
    working=[]; disabled=[]; transient=[]
    for pr in providers:
        pid=str(pr.get("id") or pr.get("name") or "").strip().lower()
        if pid=="gemini":
            disabled.append({"id":pid,"reason":"BANNED"})
            continue

        configured=str(pr.get("key_file") or "")
        passed=False
        last=("NO_KEY",None,False)
        used=None

        for kf in candidates(pid,configured):
            key=read_key(kf)
            if not key:
                continue
            ok,reason,model,is_transient=await test(pr,key)
            last=(reason,model,is_transient)
            if ok:
                passed=True
                used=kf
                if used != configured:
                    pr["key_file"]=used
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
        CFG.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    OUT.write_text(
        json.dumps({"disabled":disabled,"transient":transient},ensure_ascii=False,indent=2)+"\n",
        encoding="utf-8"
    )
    print("ACTIVE=", [p.get("id") or p.get("name") for p in working])
    print("DISABLED=", disabled)
    print("TRANSIENT=", transient)

asyncio.run(main())
PY

systemctl restart gemini-backend.service
for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/provider-httpx-health.json 2>/dev/null && break
  sleep 1
done

echo "=== HEALTH ==="
cat /tmp/provider-httpx-health.json
echo
echo "=== ACTIVE PROVIDERS ==="
curl -sS --max-time 5 http://127.0.0.1:8791/api/providers
echo
echo "=== DISABLED/TRANSIENT ==="
cat "$OUT"
echo
echo PROVIDER_HTTPX_AUDIT_READY
