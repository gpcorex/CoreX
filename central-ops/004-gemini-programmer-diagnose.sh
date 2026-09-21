#!/usr/bin/env bash
set -u

OUT=/var/lib/conector/gemini-programmer-diagnose.txt
mkdir -p /var/lib/conector

{
  echo "GEMINI_PROGRAMMER_DIAGNOSE"
  echo "generated_at=$(date -Is)"
  echo "host=$(hostname)"
  echo
  echo "[SERVICE]"
  systemctl status gemini-backend.service --no-pager -l 2>&1 || true
  echo
  echo "[HEALTH]"
  curl -sS -i --max-time 5 http://127.0.0.1:8791/api/health 2>&1 || true
  echo
  echo "[RECENT_LOGS]"
  journalctl -u gemini-backend.service -n 160 --no-pager 2>&1 || true
  echo
  echo "[CENTRAL_BRIDGE]"
  sed -n '1,240p' /home/ubuntu/Gemini/app/central_executor_bridge.py 2>&1 || true
  echo
  echo "[DIRECT_ENDPOINT]"
  python3 - <<'PY' 2>&1 || true
from pathlib import Path
p=Path('/home/ubuntu/Gemini/app/main.py')
s=p.read_text(encoding='utf-8')
a=s.find('@app.post("/api/chat/direct")')
if a < 0:
    print('DIRECT_ENDPOINT_NOT_FOUND')
else:
    b=s.find('\n@app.', a+1)
    if b < 0: b=min(len(s),a+18000)
    print(s[a:b])
PY
  echo
  echo "[ROUTER]"
  sed -n '400,760p' /home/ubuntu/Gemini/app/main.py 2>&1 || true
  echo
  echo "[CURRENT_TEST_FILE]"
  ls -l /tmp/gemini-chat-write.txt 2>&1 || true
  [ -f /tmp/gemini-chat-write.txt ] && cat /tmp/gemini-chat-write.txt || true
} >"$OUT"

if [ -x /usr/local/sbin/conector-publish-result ]; then
  /usr/local/sbin/conector-publish-result "$OUT" "vm-results/gemini-programmer-diagnose.txt" || true
fi

echo GEMINI_PROGRAMMER_DIAGNOSE_DONE
