#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/conector"
WWW_DIR="/srv/apps/conector/www/results"
SNAP="/usr/local/sbin/conector-snapshot"
mkdir -p "$STATE_DIR" "$WWW_DIR" /var/log/conector

cat >"$SNAP" <<'EOF'
#!/usr/bin/env bash
set -u
OUT="/var/lib/conector/status.txt"
PUB="/srv/apps/conector/www/results/status.txt"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

{
  echo "CONECTOR_STATUS_V2"
  echo "generated_at=$(date -Is)"
  echo "host=$(hostname)"
  echo "repo_head=$(git -C /opt/corex/repo rev-parse HEAD 2>/dev/null || true)"
  echo "write_authority=$(cat /var/lib/conector/write-authority 2>/dev/null || echo unknown)"
  echo

  echo "[CONECTOR]"
  for s in conector-sync.timer conector-sync.service conector-central-ops.timer conector-central-ops.service conector-api.service openclaw-gateway.service caddy central-backend; do
    printf "%s=" "$s"
    systemctl is-active "$s" 2>/dev/null || true
  done
  echo

  echo "[LEGACY_TIMERS]"
  for s in corex-sync.timer corex-central-ops.timer; do
    printf "%s=" "$s"
    systemctl is-active "$s" 2>/dev/null || true
  done
  echo

  echo "[OPENCLAW]"
  command -v openclaw 2>/dev/null || true
  openclaw --version 2>/dev/null || true
  ss -ltn 2>/dev/null | grep ':18789 ' || true
  echo

  echo "[CENTRAL]"
  for p in /srv/apps/central /opt/corex/repo /var/lib/conector /var/log/conector; do
    [ -e "$p" ] && echo "$p=present" || echo "$p=missing"
  done
  echo

  echo "[PROVIDER_KEY_FILES]"
  KEY_DIR="/home/ubuntu/Claves/providers"
  if [ -d "$KEY_DIR" ]; then
    find "$KEY_DIR" -maxdepth 2 -type f -printf '%f\n' 2>/dev/null | sed -E 's/\.(key|txt|env|json)$//' | sort -u
  else
    echo "provider_key_dir=missing"
  fi
  echo

  echo "[LISTENING]"
  ss -ltn 2>/dev/null | grep -E ':(80|443|8790|18789|8090)\b' || true
  echo

  echo "[RECENT_ERRORS]"
  journalctl -u conector-sync.service -u conector-central-ops.service -u openclaw-gateway.service --since '-15 min' -p warning --no-pager -n 80 2>/dev/null || true
} >"$TMP"

install -m 600 "$TMP" "$OUT"
install -m 644 "$TMP" "$PUB"

if command -v conector-publish-result >/dev/null 2>&1 && [ -s /etc/conector/github.token ]; then
  conector-publish-result "$OUT" "vm-results/status.txt" >/var/log/conector/publish.log 2>&1 || true
fi
EOF
chmod 755 "$SNAP"

cat >/etc/systemd/system/conector-snapshot.service <<'EOF'
[Unit]
Description=Conector sanitized status snapshot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/conector-snapshot
EOF

cat >/etc/systemd/system/conector-snapshot.timer <<'EOF'
[Unit]
Description=Refresh Conector status snapshot

[Timer]
OnBootSec=20
OnUnitActiveSec=60
AccuracySec=5
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now conector-sync.timer
if [ -f /etc/systemd/system/conector-central-ops.timer ]; then
  systemctl enable --now conector-central-ops.timer
fi
systemctl disable --now corex-sync.timer 2>/dev/null || true
systemctl disable --now corex-central-ops.timer 2>/dev/null || true
systemctl enable --now conector-snapshot.timer
systemctl start conector-snapshot.service || true

echo "CONECTOR_ACCESS_V2_READY"
