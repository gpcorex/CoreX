#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG="/var/log/corex/deploy.log"
STATE="/var/lib/corex"
LAST="$STATE/last_deployed_commit"

mkdir -p "$(dirname "$LOG")" "$STATE"

{
  echo "===== DEPLOY $(date -Is) ====="

  HEAD="$(git -C "$ROOT" rev-parse HEAD)"
  BASE=""

  if [ -f "$LAST" ]; then
    BASE="$(cat "$LAST" 2>/dev/null || true)"
  fi

  if [ -n "$BASE" ] && git -C "$ROOT" cat-file -e "$BASE^{commit}" 2>/dev/null; then
    echo "Base deploy: $BASE"
    echo "Head deploy: $HEAD"

    mapfile -t changed < <(
      git -C "$ROOT" diff --name-only "$BASE" "$HEAD" -- 'projects/*.sh' | sort
    )

    if [ "${#changed[@]}" -eq 0 ]; then
      echo "No hay scripts de proyecto nuevos o modificados."
    else
      for rel in "${changed[@]}"; do
        script="$ROOT/$rel"
        if [ -f "$script" ]; then
          echo "--- Ejecutando cambiado: $script"
          bash "$script"
        fi
      done
    fi
  else
    echo "Sin base válida; ejecución inicial completa."
    if [ -d "$ROOT/projects" ]; then
      while IFS= read -r -d '' script; do
        echo "--- Ejecutando inicial: $script"
        bash "$script"
      done < <(find "$ROOT/projects" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)
    fi
  fi

  echo "$HEAD" >"$LAST"
  echo "DEPLOY_COMPLETE"
} >>"$LOG" 2>&1
