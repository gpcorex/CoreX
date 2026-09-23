#!/usr/bin/env bash
set -euo pipefail
OUT=/var/lib/conector/auditor-ui-probe.txt
{
  echo "AUDITOR_UI_PROBE_V1"
  echo "generated_at=$(date -Is)"
  echo
  echo "[SERVER_RELEVANT]"
  F=/home/ubuntu/Central/auditor_ui_v1/server.py
  if [ -f "$F" ]; then
    grep -n -C 12 -E 'log|tail|Últim|ultim|stage|progress|download|copy|clipboard|textarea|pre' "$F" | head -n 500
  else
    echo "MISSING $F"
  fi
  echo
  echo "[SCAFFOLD_FULL]"
  nl -ba /home/ubuntu/Central/clean_adapter_scaffold_v1/build_clean_adapter_scaffold.py | sed -n '1,220p'
} >"$OUT"
/usr/local/sbin/conector-publish-result "$OUT" "vm-results/auditor-ui-probe.txt"
echo AUDITOR_UI_PROBE_DONE
