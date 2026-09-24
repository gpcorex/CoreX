#!/usr/bin/env bash
set -u

OUT="/var/lib/conector/xuper-runtime-start.txt"
mkdir -p /var/lib/conector
: > "$OUT"

{
  echo "XUPER_RUNTIME_START"
  echo "timestamp=$(date -Is)"
  echo
  echo "=== START SERVICES ==="
  systemctl start android-runtime.service 2>&1 || true
  sleep 3
  systemctl start android-novnc.service 2>&1 || true
  sleep 2
  echo
  echo "=== SERVICE STATE ==="
  systemctl is-active android-runtime.service 2>&1 || true
  systemctl is-active android-novnc.service 2>&1 || true
  echo
  echo "=== UNIT EXECSTART ==="
  systemctl show android-runtime.service -p ExecStart --no-pager 2>&1 || true
  systemctl show android-novnc.service -p ExecStart --no-pager 2>&1 || true
  echo
  echo "=== LISTEN PORTS ==="
  ss -ltnp 2>&1 | grep -E '(:5555|:5901|:6080|qemu|websockify)' || true
  echo
  echo "=== QEMU PROCESS ==="
  ps -ef | grep -E '[q]emu|[w]ebsockify|[n]ovnc' || true
  echo
  echo "=== RECENT RUNTIME LOG ==="
  journalctl -u android-runtime.service -n 80 --no-pager 2>&1 || true
} >> "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-runtime-start.txt" || true
fi

echo "XUPER_RUNTIME_START_READY"
tail -80 "$OUT"
