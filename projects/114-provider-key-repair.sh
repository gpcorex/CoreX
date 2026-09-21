#!/usr/bin/env bash
set -euo pipefail

CFG=/home/ubuntu/Gemini/config/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/provider-key-repair-$STAMP
mkdir -p "$BACKUP"
cp -a "$CFG" "$BACKUP/providers.json"
export BACKUP_DIR="$BACKUP"

PYTHON=/usr/bin/python3
if [ -x /home/ubuntu/Gemini/.venv/bin/python ]; then
  PYTHON=/home/ubuntu/Gemini/.venv/bin/python
fi

"$PYTHON" - <<'PY'
import asyncio, json, os, shutil
from pathlib import Path
import httpx

CFG=Path("/home/ubuntu/Gemini/config/providers.json")
BACKUP=Path(os.environ["BACKUP_DIR"])
data=json.loads(CFG.read_text(encoding="utf-8"))
providers=data.get("providers", [])

def normalize_secret(path: str):
    p=Path(path)
    raw=p.read_bytes()
    text=raw.decode("utf-8-sig").strip()
    lines=[x.strip() for x in text.splitlines() if x.strip()]
    if not lines:
        raise ValueError("EMPTY_KEY")
    value=lines[0]
    if "=" in value and not value.startswith(("sk-","gsk_")):
        value=value.split("=",1)[1].strip()
    if len(value)>=2 and value[0]==value[-1] and value[0] in {"'", '"'}:
        value=value[1:-1].strip()
    value=value.replace("\ufeff","").strip()
    value.encode("ascii")
    return value

async def test_provider(pr,key):
    pid=str(pr.get("id") or "").lower()
    base=str(pr.get("base_url") or "").rstrip("/")
    headers={"Authorization":f"Bearer {key}","Content-Type":"application/json"}

    if pid=="openrouter":
        headers["HTTP-Referer"]="http://127.0.0.1"
        headers["X-Title"]="Central"
        async with httpx.AsyncClient(timeout=20.0) as c:
            r=await c.get(base+"/models",headers=headers)
        if r.status_code in (401,403): return False,f"AUTH_{r.status_code}",None
        if r.status_code>=400: return False,f"MODELS_HTTP_{r.status_code}",None
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
            if free: model=free[0]
        except Exception:
            pass
    else:
        model=str(pr.get("model") or "")

    payload={"model":model,"messages":[{"role":"user","content":"Reply only OK"}],"temperature":0,"max_tokens":8}
    async with httpx.AsyncClient(timeout=30.0) as c:
        r=await c.post(base+"/chat/completions",headers=headers,json=payload)

    if r.status_code in (401,403): return False,f"AUTH_{r.status_code}",model
    if r.status_code==429: return False,"RATE_LIMIT_429",model
    if r.status_code>=400: return False,f"HTTP_{r.status_code}",model
    try:
        j=r.json()
        choices=j.get("choices") or []
        txt=((choices[0].get("message") or {}).get("content") if choices else "") or ""
        if not str(txt).strip():
            return False,"EMPTY_RESPONSE",model
    except Exception:
        return False,"BAD_JSON",model
    return True,"OK",model

async def main():
    kept=[]
    disabled=[]

    for pr in providers:
        pid=str(pr.get("id") or pr.get("name") or "").strip().lower()
        if pid=="gemini":
            disabled.append({"id":pid,"reason":"BANNED"})
            continue

        kf=str(pr.get("key_file") or "")
        if not kf:
            disabled.append({"id":pid,"reason":"NO_KEY_FILE"})
            print(f"DISABLE {pid} NO_KEY_FILE")
            continue

        try:
            key=normalize_secret(kf)
        except Exception as e:
            disabled.append({"id":pid,"reason":f"BAD_KEY_FILE_{type(e).__name__}"})
            print(f"DISABLE {pid} BAD_KEY_FILE_{type(e).__name__}")
            continue

        p=Path(kf)
        try:
            shutil.copy2(p, BACKUP / p.name)
        except Exception:
            pass
        p.write_text(key+"\n",encoding="ascii")

        try:
            ok,reason,model=await test_provider(pr,key)
        except Exception as e:
            ok=False
            reason="NETWORK_"+type(e).__name__
            model=None

        if ok:
            kept.append(pr)
            print(f"PASS {pid} model={model}")
        else:
            disabled.append({"id":pid,"reason":reason})
            print(f"DISABLE {pid} reason={reason} model={model}")

    if not kept:
        raise SystemExit("NO_WORKING_PROVIDERS_AFTER_REAL_TEST")

    data["providers"]=kept
    CFG.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    Path("/home/ubuntu/Gemini/config/providers.disabled.json").write_text(
        json.dumps({"disabled":disabled},ensure_ascii=False,indent=2)+"\n",
        encoding="utf-8"
    )
    print("ACTIVE=", [p.get("id") or p.get("name") for p in kept])
    print("DISABLED=", disabled)

asyncio.run(main())
PY

systemctl restart gemini-backend.service

echo "=== ACTIVE PROVIDERS ==="
curl -sS --max-time 5 http://127.0.0.1:8791/api/providers
echo
echo PROVIDER_KEY_REPAIR_READY
