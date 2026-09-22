#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-http-fix-$STAMP

mkdir -p "$BACKUP"
cp -a "$DEST/providers.py" "$BACKUP/providers.py"

echo "=== 1. PATCH HTTP HEADERS ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Central/native_v1/providers.py")
s=p.read_text(encoding="utf-8")
old='''            headers={
                "Authorization":"Bearer "+self.api_key,
                "Content-Type":"application/json",
            },
'''
new='''            headers={
                "Authorization":"Bearer "+self.api_key,
                "Content-Type":"application/json",
                "Accept":"application/json",
                "User-Agent":"Central-Native/1.0",
            },
'''
if old not in s:
    raise SystemExit("PROVIDERS_HEADER_ANCHOR_NOT_FOUND")
p.write_text(s.replace(old,new,1),encoding="utf-8")
PY
python3 -m py_compile "$DEST/providers.py"
echo PROVIDERS_HTTP_HEADERS_OK

echo "=== 2. RADAR REAL SMOKE ==="
PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from radar import scan
s=load_settings()
out=scan(s.groq_key,s.openrouter_key,20)
print("groq=",out["groq"]["ok"],"count=",out["groq"]["count"],"error=",out["groq"].get("error"))
print("openrouter=",out["openrouter"]["ok"],"count=",out["openrouter"]["count"],"error=",out["openrouter"].get("error"))
assert out["groq"]["ok"], out["groq"]
assert out["groq"]["count"] > 0
assert out["openrouter"]["ok"], out["openrouter"]
assert out["openrouter"]["count"] > 0
print("RADAR_REAL_OK")
PY

echo "=== 3. PROVIDER REAL SMOKE ==="
PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import groq_provider
s=load_settings()
p=groq_provider(s.groq_key,30)
r=p.chat("openai/gpt-oss-20b",[{"role":"user","content":"Respondé exactamente NATIVE_PROVIDER_OK"}],max_tokens=80)
ans=((r.get("choices") or [{}])[0].get("message") or {}).get("content","").strip()
print("answer=",repr(ans))
assert ans=="NATIVE_PROVIDER_OK", repr(ans)
print("PROVIDER_REAL_OK")
PY

echo "=== 4. NATIVE AGENT REAL SMOKE ==="
WORK=/tmp/central-native-smoke
rm -rf "$WORK"
mkdir -p "$WORK"
PYTHONPATH="$DEST" python3 "$DEST/cli.py" \
  "Creá un archivo prueba.txt con el texto NATIVE_AGENT_OK y después leelo para verificarlo." \
  --role rapido --workspace "$WORK" --max-steps 8 | tee /tmp/central-native-agent-smoke.json

grep -q 'NATIVE_AGENT_OK' "$WORK/prueba.txt"
echo AGENT_REAL_OK

echo "=== 5. FINAL UNIT REGRESSION ==="
PYTHONPATH="$DEST" python3 -m unittest discover -s "$DEST/tests" -p 'test_*.py' -v
echo UNIT_REGRESSION_OK

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "direct",
  "tests": "passed",
  "radar_real": "passed",
  "provider_real": "passed",
  "agent_real": "passed",
  "active": false
}
EOF

chown -R ubuntu:ubuntu "$DEST"
echo CENTRAL_NATIVE_V1_DIRECT_READY
echo "backup=$BACKUP"
echo "NOTE=inactive; no production route changed"
