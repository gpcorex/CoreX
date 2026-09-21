#!/usr/bin/env bash
set -euo pipefail

OUT=/var/lib/conector/chatgpt-bridge-probe.txt
mkdir -p /var/lib/conector

{
  echo "CHATGPT_BRIDGE_PROBE_OK"
  echo "generated_at=$(date -Is)"
  echo "host=$(hostname)"
  echo "gemini_backend=$(systemctl is-active gemini-backend.service 2>/dev/null || true)"
  echo "central_ops=$(systemctl is-active corex-central-ops.timer 2>/dev/null || true)"
} > "$OUT"

if [ -x /usr/local/sbin/conector-publish-result ]; then
  /usr/local/sbin/conector-publish-result "$OUT" "vm-results/chatgpt-bridge-probe.txt" || true
fi

echo CHATGPT_BRIDGE_PROBE_DONE
