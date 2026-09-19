#!/usr/bin/env bash
set -u
echo "[CONECTOR]"
for s in conector-sync.timer conector-sync.service conector-central-ops.timer conector-central-ops.service; do
  printf "%s=" "$s"
  systemctl is-active "$s" 2>/dev/null || true
done
echo
echo "[LEGACY]"
for s in corex-sync.timer corex-sync.service corex-central-ops.timer corex-central-ops.service; do
  printf "%s=" "$s"
  systemctl is-active "$s" 2>/dev/null || true
done
echo
echo "[COMMANDS]"
for c in /usr/local/sbin/conector-sync /usr/local/sbin/conector-central-ops /usr/local/sbin/corex-sync /usr/local/sbin/corex-central-ops; do
  if [ -L "$c" ]; then echo "$c -> $(readlink -f "$c")"; elif [ -e "$c" ]; then echo "$c present"; else echo "$c missing"; fi
done
echo
echo "[STATE]"
for p in /var/lib/conector /var/log/conector /var/lib/corex /var/log/corex; do
  [ -e "$p" ] && echo "$p present" || echo "$p missing"
done
