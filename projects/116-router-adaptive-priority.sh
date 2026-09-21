#!/usr/bin/env bash
set -euo pipefail

MAIN=/home/ubuntu/Gemini/app/main.py
CFG=/home/ubuntu/Gemini/config/providers.json
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/router-adaptive-$STAMP
mkdir -p "$BACKUP"
cp -a "$MAIN" "$BACKUP/main.py"
cp -a "$CFG" "$BACKUP/providers.json"

python3 - <<'PY'
import json
from pathlib import Path

cfg=Path("/home/ubuntu/Gemini/config/providers.json")
data=json.loads(cfg.read_text(encoding="utf-8"))
providers=data.get("providers", [])

# Gemini stays banned. Restore OpenRouter from an earlier backup only if a cleanup removed it.
providers=[
    p for p in providers
    if str(p.get("id") or p.get("name") or "").lower() != "gemini"
]

if not any(str(p.get("id") or "").lower()=="openrouter" for p in providers):
    candidates=sorted(
        Path("/home/ubuntu/Gemini/backups").glob("**/providers.json"),
        key=lambda p:p.stat().st_mtime,
        reverse=True,
    )
    restored=None
    for bp in candidates:
        try:
            old=json.loads(bp.read_text(encoding="utf-8"))
        except Exception:
            continue
        for p in old.get("providers", []):
            if str(p.get("id") or "").lower()=="openrouter":
                restored=p
                break
        if restored:
            break
    if restored:
        restored["key_file"]="/home/ubuntu/Claves/providers/openrouter.key"
        providers.append(restored)
        print("OPENROUTER_RESTORED_FROM_BACKUP")
    else:
        providers.append({
            "id":"openrouter",
            "type":"openai",
            "model":"openrouter/free",
            "base_url":"https://openrouter.ai/api/v1",
            "key_file":"/home/ubuntu/Claves/providers/openrouter.key",
        })
        print("OPENROUTER_RECREATED")

data["providers"]=providers
cfg.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("CONFIG_PROVIDERS=", [p.get("id") or p.get("name") for p in providers])
PY

python3 - <<'PY'
from pathlib import Path
import re

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

if "# ADAPTIVE_PROVIDER_ORDER" not in s:
    anchor="async def routed_answer(messages):\n"
    pos=s.find(anchor)
    if pos < 0:
        raise SystemExit("ROUTED_ANSWER_NOT_FOUND")

    helper=r'''
# ADAPTIVE_PROVIDER_ORDER
def _provider_order_by_evidence(providers):
    """
    Preserve the established Router policy:
    operational availability first, then current real evidence.
    Among comparable free providers, prefer recent success and lower latency.
    Unknown providers are not penalized; config order breaks ties.
    """
    providers=list(providers)

    stats={}
    try:
        with db() as c:
            rows=c.execute(
                """
                SELECT provider, ok, latency_ms, created_at
                FROM provider_metrics
                ORDER BY id DESC
                LIMIT 200
                """
            ).fetchall()
        for row in rows:
            pid=row["provider"]
            bucket=stats.setdefault(pid, {"ok":0,"fail":0,"lat":[]})
            if row["ok"]:
                bucket["ok"] += 1
                if row["latency_ms"] is not None:
                    bucket["lat"].append(int(row["latency_ms"]))
            else:
                bucket["fail"] += 1
    except Exception:
        return providers

    def key(item):
        idx, provider=item
        pid=provider.get("id")
        st=stats.get(pid)
        if not st:
            # No evidence yet: keep neutral and preserve config order.
            return (1, 0.0, 10**9, idx)

        total=st["ok"] + st["fail"]
        rate=(st["ok"] / total) if total else 0.0
        lat=sorted(st["lat"])
        median=(lat[len(lat)//2] if lat else 10**9)

        # Providers with at least one recent success dominate providers
        # with only failures; then success ratio; then latency.
        success_class=0 if st["ok"] > 0 else 2
        return (success_class, -rate, median, idx)

    return [
        provider
        for _, provider in sorted(
            enumerate(providers),
            key=key,
        )
    ]


def _openrouter_order_by_evidence(models):
    """
    Same policy inside OpenRouter: each free model is an independent
    candidate. Recent proven models first; unknown models stay neutral;
    models with only recent failures fall to the back.
    """
    models=list(models)
    if not models:
        return models

    stats={}
    try:
        with db() as c:
            rows=c.execute(
                """
                SELECT model, ok, latency_ms
                FROM provider_metrics
                WHERE provider='openrouter'
                  AND model IS NOT NULL
                ORDER BY id DESC
                LIMIT 400
                """
            ).fetchall()
        for row in rows:
            model=row["model"]
            bucket=stats.setdefault(model, {"ok":0,"fail":0,"lat":[]})
            if row["ok"]:
                bucket["ok"] += 1
                if row["latency_ms"] is not None:
                    bucket["lat"].append(int(row["latency_ms"]))
            else:
                bucket["fail"] += 1
    except Exception:
        return models

    def key(item):
        idx, model=item
        st=stats.get(model)
        if not st:
            # Unknown = neutral. Existing discovery order (capacity/context)
            # remains the tiebreaker.
            return (1, 0.0, 10**9, idx)

        total=st["ok"] + st["fail"]
        rate=(st["ok"] / total) if total else 0.0
        lat=sorted(st["lat"])
        median=(lat[len(lat)//2] if lat else 10**9)
        success_class=0 if st["ok"] > 0 else 2
        return (success_class, -rate, median, idx)

    ordered=[
        model
        for _, model in sorted(
            enumerate(models),
            key=key,
        )
    ]

    # OpenRouter's own free router remains final fallback, not first choice.
    if "openrouter/free" in ordered:
        ordered=[
            m for m in ordered
            if m != "openrouter/free"
        ] + ["openrouter/free"]

    return ordered


'''
    s=s[:pos]+helper+s[pos:]

    old='''    for provider in load_providers():
'''
    rpos=s.find(anchor)
    loop=s.find(old,rpos)
    if loop < 0:
        raise SystemExit("ROUTED_PROVIDER_LOOP_NOT_FOUND")
    s=s[:loop]+'''    for provider in _provider_order_by_evidence(load_providers()):
'''+s[loop+len(old):]
    p.write_text(s,encoding="utf-8")
    print("ADAPTIVE_PROVIDER_ORDER_ADDED")
else:
    print("ADAPTIVE_PROVIDER_ORDER_ALREADY_PRESENT")
PY

python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

# Rank the discovered free OpenRouter models using the same evidence policy.
needle='''    pool = await _openrouter_free_models(provider, key)

    now = int(time.time())
'''
replacement='''    pool = await _openrouter_free_models(provider, key)
    pool = _openrouter_order_by_evidence(pool)

    now = int(time.time())
'''
if needle in s and "_openrouter_order_by_evidence(pool)" not in s:
    s=s.replace(needle,replacement,1)
    print("OPENROUTER_ADAPTIVE_ORDER_ADDED")
elif "_openrouter_order_by_evidence(pool)" in s:
    print("OPENROUTER_ADAPTIVE_ORDER_ALREADY_PRESENT")
else:
    raise SystemExit("OPENROUTER_POOL_ANCHOR_NOT_FOUND")

# Record internal model failures so future routing learns which OpenRouter
# model to avoid, while the outer routed_answer records the successful model.
repls=[
(
'''            failures.append(f"{model}:NETWORK")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 60
''',
'''            failures.append(f"{model}:NETWORK")
            save_metric("openrouter", model, False, 0, "NETWORK")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 60
'''
),
(
'''            failures.append(f"{model}:RATE_LIMIT")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 600
''',
'''            failures.append(f"{model}:RATE_LIMIT")
            save_metric("openrouter", model, False, 0, "RATE_LIMIT")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 600
'''
),
(
'''            failures.append(f"{model}:HTTP_{response.status_code}")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 120
''',
'''            failures.append(f"{model}:HTTP_{response.status_code}")
            save_metric("openrouter", model, False, 0, f"HTTP_{response.status_code}")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 120
'''
),
(
'''            failures.append(f"{model}:HTTP_{response.status_code}")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 1800
''',
'''            failures.append(f"{model}:HTTP_{response.status_code}")
            save_metric("openrouter", model, False, 0, f"HTTP_{response.status_code}")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 1800
'''
),
(
'''            failures.append(f"{model}:EMPTY_RESPONSE")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 300
''',
'''            failures.append(f"{model}:EMPTY_RESPONSE")
            save_metric("openrouter", model, False, 0, "EMPTY_RESPONSE")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 300
'''
),
]
for old,new in repls:
    if old in s and new not in s:
        s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
print("OPENROUTER_MODEL_FAILURE_LEARNING_READY")
PY

python3 -m py_compile "$MAIN"
systemctl restart gemini-backend.service

for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/router-adaptive-health.json 2>/dev/null && break
  sleep 1
done

echo "=== HEALTH ==="
cat /tmp/router-adaptive-health.json
echo
echo "=== PROVIDERS ==="
curl -sS --max-time 5 http://127.0.0.1:8791/api/providers
echo
echo "=== ROUTER PATCH ==="
grep -n 'ADAPTIVE_PROVIDER_ORDER\|_provider_order_by_evidence\|_openrouter_order_by_evidence' "$MAIN"
echo
echo ROUTER_ADAPTIVE_PRIORITY_READY
