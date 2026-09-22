#!/usr/bin/env bash
set -euo pipefail

MAIN=/home/ubuntu/Gemini/app/main.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/router-provider-fix-$STAMP
mkdir -p "$BACKUP"
cp -a "$MAIN" "$BACKUP/main.py"

python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

marker="# CANONICAL_PROVIDER_CALL_V2"
if marker in s:
    print("CANONICAL_PROVIDER_CALL_V2_PRESENT")
else:
    anchor="async def routed_answer(messages):\\n"
    pos=s.find(anchor)
    if pos < 0:
        raise SystemExit("ROUTED_ANSWER_NOT_FOUND")

    block=r'''
# CANONICAL_PROVIDER_CALL_V2
async def _or_free_models_v2(provider, key):
    headers={
        "Authorization":f"Bearer {key}",
        "Content-Type":"application/json",
        "HTTP-Referer":"http://127.0.0.1",
        "X-Title":"Central",
    }
    url=provider["base_url"].rstrip("/")+"/models"
    async with httpx.AsyncClient(timeout=20.0) as c:
        r=await c.get(url,headers=headers)
    if r.status_code in {401,403}:
        raise RuntimeError("AUTH_ERROR")
    if r.status_code>=400:
        raise RuntimeError(f"MODELS_HTTP_{r.status_code}")
    out=[]
    for m in (r.json().get("data") or []):
        mid=str(m.get("id") or "")
        pr=m.get("pricing") or {}
        pp=str(pr.get("prompt",""))
        cp=str(pr.get("completion",""))
        free=mid.endswith(":free") or (pp in {"0","0.0","0.000000"} and cp in {"0","0.0","0.000000"})
        if free and mid:
            out.append(mid)
    if "openrouter/free" not in out:
        out.append("openrouter/free")
    return out[:24]

async def _call_openrouter_v2(provider,messages,key):
    headers={
        "Authorization":f"Bearer {key}",
        "Content-Type":"application/json",
        "HTTP-Referer":"http://127.0.0.1",
        "X-Title":"Central",
    }
    url=provider["base_url"].rstrip("/")+"/chat/completions"
    models=await _or_free_models_v2(provider,key)
    failures=[]
    for model in models:
        try:
            async with httpx.AsyncClient(timeout=60.0) as c:
                r=await c.post(url,headers=headers,json={
                    "model":model,
                    "messages":messages,
                    "temperature":0.3,
                })
        except Exception:
            failures.append(f"{model}:NETWORK")
            continue
        # /models already validated the key. A per-model 401/403 is a route/model
        # failure, not proof that the OpenRouter key is invalid.
        if r.status_code in {401,403,404,429} or r.status_code>=500:
            failures.append(f"{model}:HTTP_{r.status_code}")
            continue
        if r.status_code>=400:
            failures.append(f"{model}:HTTP_{r.status_code}")
            continue
        try:
            data=r.json()
            choices=data.get("choices") or []
            msg=(choices[0].get("message") or {}) if choices else {}
            text=str(msg.get("content") or "").strip()
        except Exception:
            text=""
        if text:
            return text, data.get("model") or model
        failures.append(f"{model}:EMPTY")
    raise RuntimeError("OPENROUTER_POOL_EXHAUSTED:"+("|".join(failures[-10:])))

async def _hf_zero_routes_v2(provider,key):
    headers={"Authorization":f"Bearer {key}"}
    url=provider["base_url"].rstrip("/")+"/models"
    async with httpx.AsyncClient(timeout=20.0) as c:
        r=await c.get(url,headers=headers)
    if r.status_code in {401,403}:
        raise RuntimeError("AUTH_ERROR")
    if r.status_code>=400:
        raise RuntimeError(f"MODELS_HTTP_{r.status_code}")
    def zero(v):
        try:
            return float(v)==0.0
        except Exception:
            return False
    routes=[]
    for m in (r.json().get("data") or []):
        mid=str(m.get("id") or "")
        for pr in (m.get("providers") or []):
            if str(pr.get("status") or "").lower()!="live":
                continue
            pricing=pr.get("pricing") or {}
            if not (bool(pr.get("is_free")) or (zero(pricing.get("input")) and zero(pricing.get("output")))):
                continue
            pname=str(pr.get("provider") or "")
            if mid and pname:
                routes.append(f"{mid}:{pname}")
    return routes[:40]

async def _call_hf_v2(provider,messages,key):
    headers={
        "Authorization":f"Bearer {key}",
        "Content-Type":"application/json",
    }
    url=provider["base_url"].rstrip("/")+"/chat/completions"
    routes=await _hf_zero_routes_v2(provider,key)
    if not routes:
        raise RuntimeError("HF_NO_ZERO_COST_ROUTES")
    failures=[]
    for route in routes:
        try:
            async with httpx.AsyncClient(timeout=60.0) as c:
                r=await c.post(url,headers=headers,json={
                    "model":route,
                    "messages":messages,
                    "temperature":0.3,
                })
        except Exception:
            failures.append(f"{route}:NETWORK")
            continue
        if r.status_code in {400,401,403,404,429} or r.status_code>=500:
            failures.append(f"{route}:HTTP_{r.status_code}")
            continue
        try:
            data=r.json()
            choices=data.get("choices") or []
            msg=(choices[0].get("message") or {}) if choices else {}
            text=str(msg.get("content") or "").strip()
        except Exception:
            text=""
        if text:
            return text, data.get("model") or route
        failures.append(f"{route}:EMPTY")
    raise RuntimeError("HF_ZERO_POOL_EXHAUSTED:"+("|".join(failures[-10:])))

async def call_openai(provider,messages):
    key=read_key(provider)
    pid=provider.get("id")

    if pid=="openrouter":
        return await _call_openrouter_v2(provider,messages,key)

    if pid=="huggingface":
        return await _call_hf_v2(provider,messages,key)

    bounded=messages
    if pid=="groq":
        # Keep the full request comfortably below Groq's context/payload limits.
        budget=12000
        kept=[]
        used=0
        for msg in reversed(messages):
            item=dict(msg)
            content=item.get("content","")
            if not isinstance(content,str):
                content=str(content)
            left=budget-used
            if left<=0:
                break
            if len(content)>left:
                content=content[-left:]
            item["content"]=content
            kept.append(item)
            used+=len(content)
        bounded=list(reversed(kept))

    url=provider["base_url"].rstrip("/")+"/chat/completions"
    headers={
        "Authorization":f"Bearer {key}",
        "Content-Type":"application/json",
    }
    body={
        "model":provider["model"],
        "messages":bounded,
        "temperature":0.3,
    }
    if pid=="groq" and provider.get("model") in {"openai/gpt-oss-120b","openai/gpt-oss-20b"}:
        body["include_reasoning"]=False
        body["max_completion_tokens"]=2048

    async with httpx.AsyncClient(timeout=90.0) as c:
        r=await c.post(url,headers=headers,json=body)

    if r.status_code==429:
        raise RuntimeError("RATE_LIMIT")
    if r.status_code in {401,403}:
        raise RuntimeError("AUTH_ERROR")
    if r.status_code>=400:
        raise RuntimeError(f"HTTP_{r.status_code}")

    data=r.json()
    choices=data.get("choices") or []
    if not choices:
        raise RuntimeError("EMPTY_RESPONSE")
    msg=choices[0].get("message") or {}
    text=str(msg.get("content") or "").strip()
    if not text:
        raise RuntimeError("EMPTY_RESPONSE")
    return text, data.get("model") or provider["model"]


'''
    s=s[:pos]+block+s[pos:]
    p.write_text(s,encoding="utf-8")
    print("CANONICAL_PROVIDER_CALL_V2_ADDED")
PY

python3 -m py_compile "$MAIN"

python3 - <<'PY'
import sqlite3
from pathlib import Path
db=Path("/home/ubuntu/Gemini/data/gemini.db")
if db.exists():
    con=sqlite3.connect(db)
    tables={r[0] for r in con.execute("select name from sqlite_master where type='table'")}
    if "provider_state" in tables:
        con.execute("delete from provider_state")
        con.commit()
        print("PROVIDER_STATE_CLEARED")
    con.close()
PY

systemctl restart gemini-backend.service

for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/router-v2-health.json 2>/dev/null && break
  sleep 1
done

echo "=== HEALTH ==="
cat /tmp/router-v2-health.json
echo
echo "=== PROVIDERS ==="
curl -sS --max-time 5 http://127.0.0.1:8791/api/providers; echo
echo
echo ROUTER_PROVIDER_CALL_V2_READY
