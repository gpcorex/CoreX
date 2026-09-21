#!/usr/bin/env bash
set -euo pipefail

MAIN=/home/ubuntu/Gemini/app/main.py
CFG=/home/ubuntu/Gemini/config/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/key-normalize-$STAMP
mkdir -p "$BACKUP"
cp -a "$MAIN" "$BACKUP/main.py"
cp -a "$CFG" "$BACKUP/providers.json"

python3 - <<'PY'
from pathlib import Path
import re

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

m=re.search(r'^def read_key\(provider\):\n(?:^[ \t]+.*\n)+', s, flags=re.M)
if not m:
    raise SystemExit("READ_KEY_FUNCTION_NOT_FOUND")

replacement='''def read_key(provider):
    path = provider.get("key_file")
    if not path:
        raise RuntimeError("MISSING_KEY_FILE")

    raw = Path(path).read_text(
        encoding="utf-8-sig"
    ).strip()

    lines = [
        x.strip()
        for x in raw.splitlines()
        if x.strip()
        and not x.strip().startswith("#")
    ]

    if not lines:
        raise RuntimeError("EMPTY_KEY")

    value = lines[0]

    if value.lower().startswith("export "):
        value = value[7:].strip()

    if "=" in value:
        left, right = value.split("=", 1)
        lname = left.strip().lower()
        if any(
            token in lname
            for token in ("key", "token", "secret")
        ):
            value = right.strip()

    value = value.strip().strip('"').strip("'")
    value = value.replace("\ufeff", "").strip()

    try:
        value.encode("ascii")
    except UnicodeEncodeError:
        raise RuntimeError("KEY_NON_ASCII")

    if not value:
        raise RuntimeError("EMPTY_KEY")

    return value
'''

s=s[:m.start()]+replacement+s[m.end():]
p.write_text(s,encoding="utf-8")
print("READ_KEY_NORMALIZED")
PY

python3 -m py_compile "$MAIN"

PYTHON=/usr/bin/python3
if [ -x /home/ubuntu/Gemini/.venv/bin/python ]; then
  PYTHON=/home/ubuntu/Gemini/.venv/bin/python
fi

"$PYTHON" - <<'PY'
import asyncio, json
from pathlib import Path
import httpx

CFG=Path("/home/ubuntu/Gemini/config/providers.json")
data=json.loads(CFG.read_text(encoding="utf-8"))
providers=data.get("providers", [])

def clean_key(path):
    raw=Path(path).read_text(encoding="utf-8-sig").strip()
    lines=[x.strip() for x in raw.splitlines() if x.strip() and not x.strip().startswith("#")]
    if not lines:
        raise RuntimeError("EMPTY_KEY")
    v=lines[0]
    if v.lower().startswith("export "):
        v=v[7:].strip()
    if "=" in v:
        left,right=v.split("=",1)
        if any(t in left.strip().lower() for t in ("key","token","secret")):
            v=right.strip()
    v=v.strip().strip('"').strip("'").replace("\ufeff","").strip()
    v.encode("ascii")
    return v

async def test(pr):
    pid=str(pr.get("id") or "").lower()
    key=clean_key(pr.get("key_file"))
    base=str(pr.get("base_url") or "").rstrip("/")
    headers={"Authorization":f"Bearer {key}","Content-Type":"application/json"}

    if pid=="openrouter":
        headers["HTTP-Referer"]="http://127.0.0.1"
        headers["X-Title"]="Central"
        async with httpx.AsyncClient(timeout=20.0) as c:
            r=await c.get(base+"/models",headers=headers)
        if r.status_code in (401,403):
            return False,f"AUTH_{r.status_code}"
        if r.status_code>=400:
            return False,f"MODELS_HTTP_{r.status_code}"
        model="openrouter/free"
    else:
        model=str(pr.get("model") or "")

    payload={
        "model":model,
        "messages":[{"role":"user","content":"Reply only OK"}],
        "temperature":0,
        "max_tokens":8,
    }
    async with httpx.AsyncClient(timeout=30.0) as c:
        r=await c.post(base+"/chat/completions",headers=headers,json=payload)

    if r.status_code in (401,403):
        return False,f"AUTH_{r.status_code}"
    if r.status_code==429:
        return True,"VALID_KEY_RATE_LIMITED"
    if r.status_code>=400:
        return False,f"HTTP_{r.status_code}"

    try:
        j=r.json()
        ch=j.get("choices") or []
        txt=((ch[0].get("message") or {}).get("content") if ch else "") or ""
        if not str(txt).strip():
            return False,"EMPTY_RESPONSE"
    except Exception:
        return False,"BAD_JSON"

    return True,"OK"

async def main():
    keep=[]
    disabled=[]
    for pr in providers:
        pid=str(pr.get("id") or pr.get("name") or "").lower()
        if pid=="gemini":
            disabled.append({"id":pid,"reason":"BANNED"})
            continue
        try:
            ok,reason=await test(pr)
        except UnicodeEncodeError:
            ok,reason=False,"KEY_NON_ASCII"
        except Exception as e:
            ok,reason=False,"NETWORK_"+type(e).__name__

        print(("PASS" if ok else "FAIL"), pid, reason)
        if ok:
            keep.append(pr)
        else:
            disabled.append({"id":pid,"reason":reason})

    if keep:
        data["providers"]=keep
        CFG.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    Path("/home/ubuntu/Gemini/config/providers.disabled.json").write_text(
        json.dumps({"disabled":disabled},ensure_ascii=False,indent=2)+"\n",
        encoding="utf-8"
    )
    print("ACTIVE=", [p.get("id") or p.get("name") for p in keep])
    print("DISABLED=", disabled)

asyncio.run(main())
PY

systemctl restart gemini-backend.service

for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/key-normalize-health.json 2>/dev/null && break
  sleep 1
done

echo "=== HEALTH ==="
cat /tmp/key-normalize-health.json
echo
echo "=== PROVIDERS ==="
curl -sS --max-time 5 http://127.0.0.1:8791/api/providers
echo
echo "=== DISABLED ==="
cat /home/ubuntu/Gemini/config/providers.disabled.json
echo
echo PROVIDER_KEYS_NORMALIZED_AND_TESTED
