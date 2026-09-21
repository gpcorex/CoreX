#!/usr/bin/env bash
set -euo pipefail

MAIN=/home/ubuntu/Gemini/app/main.py
STAMP=$(date +%Y%m%d-%H%M%S)
cp -a "$MAIN" "$MAIN.bak-remove-legacy-write-$STAMP"

python3 - <<'PY'
from pathlib import Path

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

start_marker='    # -------------------------------------------------\n    # WRITE automático:'
end_marker='    # Programación / operación: Central gobierna, OpenClaw ejecuta.'

start=s.find(start_marker)
end=s.find(end_marker)

if start >= 0 and end > start:
    s=s[:start]+s[end:]
    print("LEGACY_AUTO_WRITE_REMOVED")
else:
    print("LEGACY_AUTO_WRITE_NOT_FOUND_OR_ALREADY_REMOVED")

p.write_text(s, encoding="utf-8")
PY

python3 -m py_compile "$MAIN"
systemctl restart gemini-backend.service

for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/gem-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done

echo "=== GEMINI HEALTH ==="
cat /tmp/gem-health.json
echo

echo "=== E2E WRITE ==="
set +e
curl -sS --max-time 420   -H 'Content-Type: application/json'   -d '{"message":"Creá /tmp/gemini-central-e2e.txt con el texto GEMINI_CENTRAL_E2E_OK","conversation_id":"central-e2e-test-2"}'   http://127.0.0.1:8791/api/chat/direct
RC=$?
set -e
echo
echo "curl_rc=$RC"

echo "=== FILE VERIFY ==="
if [ -f /tmp/gemini-central-e2e.txt ]; then
  cat /tmp/gemini-central-e2e.txt
else
  echo FILE_NOT_CREATED
fi

echo "=== RECENT GEMINI LOGS ==="
journalctl -u gemini-backend.service -n 80 --no-pager || true

echo GEMINI_LEGACY_WRITE_REMOVAL_DONE
