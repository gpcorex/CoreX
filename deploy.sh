#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG="/var/log/corex/deploy.log"
mkdir -p "$(dirname "$LOG")"

{
  echo "===== DEPLOY $(date -Is) ====="

  if [ -d "$ROOT/projects" ]; then
    while IFS= read -r -d '' script; do
      echo "--- Ejecutando: $script"
      bash "$script"
    done < <(find "$ROOT/projects" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)
  fi

  echo "DEPLOY_COMPLETE"
} >>"$LOG" 2>&1
