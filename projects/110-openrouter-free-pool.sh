#!/usr/bin/env bash
set -euo pipefail

MAIN=/home/ubuntu/Gemini/app/main.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/openrouter-pool-$STAMP
mkdir -p "$BACKUP"
cp -a "$MAIN" "$BACKUP/main.py"

python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

start=s.find("async def call_openai(provider, messages):")
end=s.find("\n\nasync def call_gemini(provider, messages):", start)
if start < 0 or end < 0:
    raise SystemExit("CALL_OPENAI_BLOCK_NOT_FOUND")

replacement = r'''OPENROUTER_FREE_CACHE = {
    "ts": 0,
    "models": [],
}
OPENROUTER_MODEL_COOLDOWN = {}


async def _openrouter_free_models(provider, key):
    now = int(time.time())

    cached = OPENROUTER_FREE_CACHE.get("models") or []
    if cached and now - int(OPENROUTER_FREE_CACHE.get("ts") or 0) < 1800:
        return cached

    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "http://127.0.0.1",
        "X-Title": "Parallel Assistant",
    }

    url = provider["base_url"].rstrip("/") + "/models"

    models = []

    try:
        async with httpx.AsyncClient(timeout=20.0) as client:
            response = await client.get(url, headers=headers)

        if response.status_code in {401, 403}:
            raise RuntimeError("AUTH_ERROR")

        if response.status_code < 400:
            data = response.json()
            for item in data.get("data") or []:
                mid = str(item.get("id") or "").strip()
                if not mid:
                    continue

                pricing = item.get("pricing") or {}
                prompt_price = str(pricing.get("prompt", "")).strip()
                completion_price = str(pricing.get("completion", "")).strip()

                is_free = (
                    mid.endswith(":free")
                    or (
                        prompt_price in {"0", "0.0", "0.000000"}
                        and completion_price in {"0", "0.0", "0.000000"}
                    )
                )

                if not is_free:
                    continue

                arch = item.get("architecture") or {}
                inputs = arch.get("input_modalities") or ["text"]
                outputs = arch.get("output_modalities") or ["text"]

                if "text" not in inputs or "text" not in outputs:
                    continue

                context = int(item.get("context_length") or 0)
                models.append((context, mid))

    except RuntimeError:
        raise
    except Exception:
        # Discovery failure does not make OpenRouter unusable.
        models = []

    # Prefer larger-context free text models, but never depend on a static list.
    models = [mid for _, mid in sorted(models, key=lambda x: (-x[0], x[1]))]

    # OpenRouter's own free router is always the last internal fallback.
    if "openrouter/free" not in models:
        models.append("openrouter/free")

    # Keep request latency bounded.
    models = models[:24]

    OPENROUTER_FREE_CACHE["ts"] = now
    OPENROUTER_FREE_CACHE["models"] = models
    return models


async def _call_openrouter_pool(provider, messages, key):
    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "http://127.0.0.1",
        "X-Title": "Parallel Assistant",
    }

    url = provider["base_url"].rstrip("/") + "/chat/completions"
    pool = await _openrouter_free_models(provider, key)

    now = int(time.time())
    failures = []

    for model in pool:
        until = int(OPENROUTER_MODEL_COOLDOWN.get(model) or 0)
        if until > now:
            continue

        body = {
            "model": model,
            "messages": messages,
            "temperature": 0.3,
        }

        try:
            async with httpx.AsyncClient(timeout=75.0) as client:
                response = await client.post(
                    url,
                    json=body,
                    headers=headers,
                )
        except Exception as exc:
            failures.append(f"{model}:NETWORK")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 60
            continue

        if response.status_code in {401, 403}:
            raise RuntimeError("AUTH_ERROR")

        if response.status_code == 429:
            failures.append(f"{model}:RATE_LIMIT")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 600
            continue

        if response.status_code >= 500:
            failures.append(f"{model}:HTTP_{response.status_code}")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 120
            continue

        if response.status_code >= 400:
            failures.append(f"{model}:HTTP_{response.status_code}")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 1800
            continue

        try:
            data = response.json()
            choices = data.get("choices") or []
            text = (
                choices[0]
                .get("message", {})
                .get("content", "")
                if choices
                else ""
            )
            text = str(text).strip()
        except Exception:
            text = ""

        if not text:
            failures.append(f"{model}:EMPTY_RESPONSE")
            OPENROUTER_MODEL_COOLDOWN[model] = now + 300
            continue

        return (
            text,
            data.get("model") or model,
        )

    raise RuntimeError(
        "OPENROUTER_POOL_EXHAUSTED:"
        + "|".join(failures[-12:])
    )


async def call_openai(provider, messages):
    key = read_key(provider)

    if provider["id"] == "openrouter":
        return await _call_openrouter_pool(
            provider,
            messages,
            key,
        )

    url = (
        provider["base_url"].rstrip("/")
        + "/chat/completions"
    )

    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }

    body = {
        "model": provider["model"],
        "messages": messages,
        "temperature": 0.3,
    }

    async with httpx.AsyncClient(
        timeout=90.0
    ) as client:
        response = await client.post(
            url,
            json=body,
            headers=headers,
        )

    if response.status_code == 429:
        raise RuntimeError("RATE_LIMIT")

    if response.status_code in {401, 403}:
        raise RuntimeError("AUTH_ERROR")

    if response.status_code >= 500:
        raise RuntimeError(
            f"HTTP_{response.status_code}"
        )

    if response.status_code >= 400:
        raise RuntimeError(
            f"HTTP_{response.status_code}"
        )

    data = response.json()

    choices = data.get("choices") or []

    if not choices:
        raise RuntimeError("EMPTY_RESPONSE")

    text = (
        choices[0]
        .get("message", {})
        .get("content", "")
    )

    if not str(text).strip():
        raise RuntimeError("EMPTY_RESPONSE")

    return (
        str(text).strip(),
        data.get("model")
        or provider["model"],
    )
'''

s = s[:start] + replacement + s[end:]
p.write_text(s, encoding="utf-8")
print("OPENROUTER_POOL_PATCH_OK")
PY

python3 -m py_compile "$MAIN"

systemctl restart gemini-backend.service

for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/gem-or-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done

echo "=== HEALTH ==="
cat /tmp/gem-or-health.json
echo

echo "=== PROVIDERS ==="
curl -fsS --max-time 5 http://127.0.0.1:8791/api/providers
echo

echo "=== OPENROUTER POOL CODE ==="
grep -n -A4 -B2 '_openrouter_free_models\|_call_openrouter_pool' "$MAIN" | head -n 60

echo
echo GEMINI_OPENROUTER_FREE_POOL_READY
