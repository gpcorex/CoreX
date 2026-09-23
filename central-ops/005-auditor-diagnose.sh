#!/usr/bin/env bash
set -euo pipefail

OUT=/var/lib/conector/auditor-diagnose.txt
mkdir -p /var/lib/conector

{
  echo "AUDITOR_DIAGNOSE_V1"
  echo "generated_at=$(date -Is)"
  echo
  echo "[PIPELINE_FILE]"
  find /home/ubuntu/Central -type f -name 'run_central_extraction.py' -print 2>/dev/null | head -20
  echo
  echo "[SCAFFOLD_CANDIDATES]"
  grep -RIl --exclude-dir='.git' 'NO_INTERFACE_OPERATIONS' /home/ubuntu/Central 2>/dev/null | head -50 || true
  echo
  echo "[LOG_UI_CANDIDATES]"
  grep -RIl --exclude-dir='.git' -E 'Últimos|ultimos|log|stage_total|progress' /home/ubuntu/Central 2>/dev/null | grep -E '\.(py|js|ts|tsx|jsx|html|css)$' | head -100 || true
  echo
  echo "[RUN_PIPELINE_EXCERPT]"
  PIPE=$(find /home/ubuntu/Central -type f -name 'run_central_extraction.py' -print -quit 2>/dev/null || true)
  if [ -n "$PIPE" ]; then
    nl -ba "$PIPE" | sed -n '1,280p'
  fi
  echo
  echo "[NO_INTERFACE_EXCERPTS]"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    echo "--- FILE: $f ---"
    grep -n -C 20 'NO_INTERFACE_OPERATIONS' "$f" || true
  done < <(grep -RIl --exclude-dir='.git' 'NO_INTERFACE_OPERATIONS' /home/ubuntu/Central 2>/dev/null | head -20)
} >"$OUT"

if [ -x /usr/local/sbin/conector-publish-result ]; then
  /usr/local/sbin/conector-publish-result "$OUT" "vm-results/auditor-diagnose.txt"
fi

echo AUDITOR_DIAGNOSE_DONE
