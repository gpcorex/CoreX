#!/usr/bin/env bash
set -euo pipefail

MAIN=/home/ubuntu/Gemini/app/main.py
CFG=/home/ubuntu/Gemini/config/providers.json
KEY=/home/ubuntu/Claves/providers/huggingface.key
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/hf-zero-pool-$STAMP
mkdir -p "$BACKUP"
cp -a "$MAIN" "$BACKUP/main.py"
cp -a "$CFG" "$BACKUP/providers.json"

[ -s "$KEY" ] || { echo "HF_KEY_MISSING"; exit 1; }

PY=/home/ubuntu/Gemini/.venv/bin/python
[ -x "$PY" ] || PY=/usr/bin/python3

echo "=== DISCOVER ZERO-COST HF ROUTES ==="
HF_DISCOVERY=$("$PY" - <<'PY'
from pathlib import Path
import asyncio, httpx, json

key=Path("/home/ubuntu/Claves/providers/huggingface.key").read_text().strip()

def zero(v):
    try:
        return float(v) == 0.0
    except Exception:
        return False

async def main():
    headers={"Authorization":f"Bearer {key}"}
    async with httpx.AsyncClient(timeout=30) as c:
        r=await c.get("https://router.huggingface.co/v1/models",headers=headers)
    print("STATUS",r.status_code)
    if r.status_code != 200:
        print("COUNT 0")
        return
    data=r.json().get("data") or []
    routes=[]
    for m in data:
        mid=str(m.get("id") or "").strip()
        if not mid:
            continue
        for pr in (m.get("providers") or []):
            if str(pr.get("status") or "").lower() != "live":
                continue
            pricing=pr.get("pricing") or {}
            is_free=bool(pr.get("is_free")) or (
                zero(pricing.get("input")) and zero(pricing.get("output"))
            )
            if not is_free:
                continue
            provider=str(pr.get("provider") or "").strip()
            if not provider:
                continue
            routes.append({
                "model":mid,
                "provider":provider,
                "route":f"{mid}:{provider}",
                "context_length":int(pr.get("context_length") or 0),
                "throughput":float(pr.get("throughput") or 0),
                "latency_ms":float(pr.get("first_token_latency_ms") or 0),
            })
    routes.sort(key=lambda x:(-x["context_length"], -x["throughput"], x["latency_ms"] or 10**12, x["route"]))
    Path("/home/ubuntu/Gemini/config/huggingface_zero_routes.json").write_text(
        json.dumps({"routes":routes},ensure_ascii=False,indent=2)+"\n",
        encoding="utf-8"
    )
    print("COUNT",len(routes))
    for x in routes[:20]:
        print("ROUTE",x["route"])

asyncio.run(main())
PY
)
echo "$HF_DISCOVERY"

HF_COUNT=$(printf '%s
' "$HF_DISCOVERY" | awk '/^COUNT /{print $2}' | tail -1)
[ -n "$HF_COUNT" ] || HF_COUNT=0

python3 - <<'PY'
import json
from pathlib import Path

cfg=Path("/home/ubuntu/Gemini/config/providers.json")
data=json.loads(cfg.read_text(encoding="utf-8"))
providers=[
    p for p in data.get("providers", [])
    if str(p.get("id") or "").lower() not in {"huggingface","gemini"}
]

routes_path=Path("/home/ubuntu/Gemini/config/huggingface_zero_routes.json")
routes=[]
if routes_path.exists():
    try:
        routes=json.loads(routes_path.read_text()).get("routes") or []
    except Exception:
        routes=[]

if routes:
    providers.append({
        "id":"huggingface",
        "type":"openai",
        "enabled":True,
        "priority":40,
        "key_file":"/home/ubuntu/Claves/providers/huggingface.key",
        "base_url":"https://router.huggingface.co/v1",
        "model":"hf-zero-pool",
        "zero_cost_only":True
    })
    print("HUGGINGFACE_ADDED",len(routes))
else:
    print("HUGGINGFACE_NOT_ADDED_NO_ZERO_ROUTES")

data["providers"]=providers
cfg.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("PROVIDERS=", [p.get("id") for p in providers])
PY

python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

marker="HF_ZERO_COST_POOL"
if marker not in s:
    anchor="async def call_openai(provider, messages):\n"
    pos=s.find(anchor)
    if pos<0:
        raise SystemExit("CALL_OPENAI_NOT_FOUND")

    helper=r'''
# HF_ZERO_COST_POOL
HUGGINGFACE_ZERO_CACHE = {"ts": 0, "routes": []}
HUGGINGFACE_ROUTE_COOLDOWN = {}


async def _huggingface_zero_routes(provider, key):
    now=int(time.time())
    cached=HUGGINGFACE_ZERO_CACHE.get("routes") or []
    if cached and now-int(HUGGINGFACE_ZERO_CACHE.get("ts") or 0) < 1800:
        return cached

    headers={"Authorization":f"Bearer {key}"}
    url=provider["base_url"].rstrip("/") + "/models"

    async with httpx.AsyncClient(timeout=25.0) as client:
        response=await client.get(url,headers=headers)

    if response.status_code in {401,403}:
        raise RuntimeError("AUTH_ERROR")
    if response.status_code >= 400:
        raise RuntimeError(f"HTTP_{response.status_code}")

    def zero(v):
        try:
            return float(v)==0.0
        except Exception:
            return False

    routes=[]
    for item in (response.json().get("data") or []):
        mid=str(item.get("id") or "").strip()
        if not mid:
            continue
        for pr in (item.get("providers") or []):
            if str(pr.get("status") or "").lower()!="live":
                continue
            pricing=pr.get("pricing") or {}
            is_free=bool(pr.get("is_free")) or (
                zero(pricing.get("input"))
                and zero(pricing.get("output"))
            )
            if not is_free:
                continue
            pname=str(pr.get("provider") or "").strip()
            if not pname:
                continue
            routes.append({
                "model":mid,
                "provider":pname,
                "route":f"{mid}:{pname}",
                "context_length":int(pr.get("context_length") or 0),
                "throughput":float(pr.get("throughput") or 0),
                "latency_ms":float(pr.get("first_token_latency_ms") or 0),
            })

    routes.sort(
        key=lambda x:(
            -x["context_length"],
            -x["throughput"],
            x["latency_ms"] or 10**12,
            x["route"],
        )
    )

    HUGGINGFACE_ZERO_CACHE["ts"]=now
    HUGGINGFACE_ZERO_CACHE["routes"]=routes
    return routes


async def _call_huggingface_zero_pool(provider, messages, key):
    headers={
        "Authorization":f"Bearer {key}",
        "Content-Type":"application/json",
    }
    url=provider["base_url"].rstrip("/") + "/chat/completions"
    routes=await _huggingface_zero_routes(provider,key)

    if not routes:
        raise RuntimeError("HF_NO_ZERO_COST_ROUTES")

    now=int(time.time())
    failures=[]

    for item in routes[:40]:
        route=item["route"]
        until=int(HUGGINGFACE_ROUTE_COOLDOWN.get(route) or 0)
        if until > now:
            continue

        body={
            "model":route,
            "messages":messages,
            "temperature":0.3,
        }

        try:
            async with httpx.AsyncClient(timeout=75.0) as client:
                response=await client.post(url,json=body,headers=headers)
        except Exception:
            failures.append(f"{route}:NETWORK")
            HUGGINGFACE_ROUTE_COOLDOWN[route]=now+60
            continue

        if response.status_code in {401,403}:
            raise RuntimeError("AUTH_ERROR")

        if response.status_code==429:
            failures.append(f"{route}:RATE_LIMIT")
            HUGGINGFACE_ROUTE_COOLDOWN[route]=now+600
            continue

        if response.status_code>=500:
            failures.append(f"{route}:HTTP_{response.status_code}")
            HUGGINGFACE_ROUTE_COOLDOWN[route]=now+120
            continue

        if response.status_code>=400:
            failures.append(f"{route}:HTTP_{response.status_code}")
            HUGGINGFACE_ROUTE_COOLDOWN[route]=now+1800
            continue

        try:
            data=response.json()
            choices=data.get("choices") or []
            text=(
                choices[0].get("message",{}).get("content","")
                if choices else ""
            )
            text=str(text).strip()
        except Exception:
            text=""

        if not text:
            failures.append(f"{route}:EMPTY_RESPONSE")
            HUGGINGFACE_ROUTE_COOLDOWN[route]=now+300
            continue

        return text, data.get("model") or route

    raise RuntimeError(
        "HF_ZERO_POOL_EXHAUSTED:"+"|".join(failures[-12:])
    )


'''
    s=s[:pos]+helper+s[pos:]

    anchor2='''    if provider["id"] == "openrouter":
        return await _call_openrouter_pool(
            provider,
            messages,
            key,
        )
'''
    pos2=s.find(anchor2,s.find("async def call_openai(provider, messages):"))
    if pos2<0:
        raise SystemExit("OPENROUTER_BRANCH_NOT_FOUND")

    insert=anchor2+'''

    if provider["id"] == "huggingface":
        return await _call_huggingface_zero_pool(
            provider,
            messages,
            key,
        )
'''
    s=s[:pos2]+insert+s[pos2+len(anchor2):]

    p.write_text(s,encoding="utf-8")
    print("HF_ZERO_POOL_PATCH_ADDED")
else:
    print("HF_ZERO_POOL_PATCH_PRESENT")
PY

python3 -m py_compile "$MAIN"

systemctl restart gemini-backend.service
for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/hf-zero-health.json 2>/dev/null && break
  sleep 1
done

echo "=== HEALTH ==="
cat /tmp/hf-zero-health.json
echo
echo "=== PROVIDERS ==="
curl -sS --max-time 5 http://127.0.0.1:8791/api/providers; echo
echo
echo "=== HF ZERO ROUTES ==="
"$PY" - <<'PY'
import json
from pathlib import Path
p=Path("/home/ubuntu/Gemini/config/huggingface_zero_routes.json")
if not p.exists():
    print("count=0")
else:
    routes=json.loads(p.read_text()).get("routes") or []
    print("count=",len(routes))
    for r in routes[:20]:
        print("-",r["route"])
PY

echo
echo HUGGINGFACE_ZERO_COST_POOL_READY
