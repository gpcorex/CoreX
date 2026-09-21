#!/usr/bin/env bash
set -euo pipefail
OUT=/srv/apps/android-bridge/www/corex-results/gemini-router-scan.txt
mkdir -p "$(dirname "$OUT")"
{
  echo "=== ROUTER SYMBOLS ==="
  grep -RIn --exclude='*.pyc' --exclude-dir='__pycache__'     -E 'def routed_answer|async def routed_answer|def call_provider|async def call_provider|RATE_LIMIT|AUTH_ERROR'     /home/ubuntu/Gemini/app /home/ubuntu/Claves/providers 2>/dev/null | head -n 200 || true
  echo
  echo "=== MAIN DIRECT QUOTA ==="
  grep -n -C 8 -E 'Gemini alcanzó temporalmente el límite de cuota|RATE_LIMIT|routed_answer|gemini_direct'     /home/ubuntu/Gemini/app/main.py 2>/dev/null | head -n 260 || true
  echo
  echo "=== IMPORTS ==="
  grep -n -E '^from .*router|^import .*router|routed_answer' /home/ubuntu/Gemini/app/main.py 2>/dev/null | head -n 120 || true
} > "$OUT"
chmod 644 "$OUT"
echo GEMINI_ROUTER_SCAN_READY
