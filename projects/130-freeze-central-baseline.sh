#!/usr/bin/env bash
set -euo pipefail

echo "=== FREEZE AUTOMATIONS ==="
for t in conector-sync.timer conector-central-ops.timer conector-snapshot.timer; do
  systemctl disable --now "$t" 2>/dev/null || true
done

echo "=== STOP LEGACY GEMINI BACKEND ==="
systemctl disable --now gemini-backend.service 2>/dev/null || true

echo "=== VERIFY CORE SERVICES ==="
for s in caddy central-jobs-api; do
  printf '%s=' "$s"
  systemctl is-active "$s.service" 2>/dev/null || true
done

UIDU="$(id -u ubuntu)"
export XDG_RUNTIME_DIR="/run/user/$UIDU"
printf 'openclaw-gateway='
runuser -u ubuntu -- env HOME=/home/ubuntu XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user is-active openclaw-gateway.service 2>/dev/null || true

echo "=== VERIFY FROZEN UNITS ==="
for t in conector-sync.timer conector-central-ops.timer conector-snapshot.timer; do
  printf '%s active=' "$t"
  systemctl is-active "$t" 2>/dev/null || true
  printf '%s enabled=' "$t"
  systemctl is-enabled "$t" 2>/dev/null || true
done

printf 'gemini-backend active='
systemctl is-active gemini-backend.service 2>/dev/null || true
printf 'gemini-backend enabled='
systemctl is-enabled gemini-backend.service 2>/dev/null || true

echo "=== RESOURCE SNAPSHOT ==="
free -h
uptime
ss -ltnp | grep -E ':(80|443|8090|8091|18789)\b' || true

echo CENTRAL_FREEZE_READY
