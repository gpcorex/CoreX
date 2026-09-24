#!/usr/bin/env bash
set -euo pipefail

OUT="/tmp/chatgpt-direct-write-proof.txt"
cat >"$OUT" <<EOF
CHATGPT_DIRECT_WRITE_OK
generated_at=$(date -Is)
host=$(hostname)
repo_head=$(git -C /opt/corex/repo rev-parse HEAD 2>/dev/null || true)
EOF
chmod 600 "$OUT"

echo "CHATGPT_DIRECT_WRITE_OK"
cat "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/chatgpt-direct-write-proof.txt" || true
fi
