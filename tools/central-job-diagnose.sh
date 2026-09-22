#!/usr/bin/env bash
set -euo pipefail
JOB_ID="${1:-}"
if [ -z "$JOB_ID" ]; then
  echo "usage: $0 TR-CENTRAL-..."
  exit 2
fi
BASE="/home/ubuntu/Central/data/api-jobs/$JOB_ID"

echo "=== JOB API ==="
curl -fsS --max-time 5 "http://127.0.0.1:8091/api/jobs/$JOB_ID" || true
echo

echo "=== JOB FILE ==="
cat "$BASE/job.json" 2>/dev/null || true
echo

echo "=== TASK ==="
cat "$BASE/task.json" 2>/dev/null || true
echo

echo "=== STDOUT ==="
cat "$BASE/stdout.txt" 2>/dev/null || true
echo

echo "=== STDERR ==="
cat "$BASE/stderr.txt" 2>/dev/null || true
echo

echo "=== EXECUTOR CURRENT ==="
grep -nE 'OPENCLAW|model|timeout|CENTRAL_STATUS|spawn|exec' /home/ubuntu/Central/runtime/executor.js 2>/dev/null || true
echo

echo "=== OPENCLAW RECENT LOGS ==="
UIDU="$(id -u ubuntu)"
runuser -u ubuntu -- env HOME=/home/ubuntu XDG_RUNTIME_DIR="/run/user/$UIDU" journalctl --user -u openclaw-gateway.service --since "-20 min" --no-pager 2>/dev/null | tail -160 || true

echo "CENTRAL_JOB_DIAG_COMPLETE"
