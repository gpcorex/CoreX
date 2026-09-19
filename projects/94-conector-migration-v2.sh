#!/usr/bin/env bash
set -euo pipefail

mkdir -p /var/lib/conector /var/log/conector

cat >/usr/local/sbin/conector-sync <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BASE="/opt/corex/repo"
LOCK="/run/conector-sync.lock"
LOG="/var/log/conector/sync.log"

exec 9>"$LOCK"
flock -n 9 || exit 0
mkdir -p "$(dirname "$LOG")"

{
  echo "===== $(date -Is) ====="
  git -C "$BASE" fetch origin main
  LOCAL="$(git -C "$BASE" rev-parse HEAD)"
  REMOTE="$(git -C "$BASE" rev-parse origin/main)"

  if [ "$LOCAL" = "$REMOTE" ]; then
    echo "Sin cambios."
    exit 0
  fi

  echo "Actualizando $LOCAL -> $REMOTE"
  git -C "$BASE" reset --hard origin/main

  if [ -x "$BASE/deploy.sh" ]; then
    "$BASE/deploy.sh"
  else
    bash "$BASE/deploy.sh"
  fi

  echo "$REMOTE" >/var/lib/conector/last_deployed_commit
  echo "Deploy OK."
} >>"$LOG" 2>&1
EOF
chmod 755 /usr/local/sbin/conector-sync

cat >/etc/systemd/system/conector-sync.service <<'EOF'
[Unit]
Description=Conector deployment sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/conector-sync
EOF

cat >/etc/systemd/system/conector-sync.timer <<'EOF'
[Unit]
Description=Run Conector sync every minute

[Timer]
OnBootSec=15
OnUnitActiveSec=60
AccuracySec=5
Persistent=true

[Install]
WantedBy=timers.target
EOF

if [ -f /usr/local/sbin/corex-central-ops ]; then
  cp -f /usr/local/sbin/corex-central-ops /usr/local/sbin/conector-central-ops
  sed -i 's#/var/lib/corex/central-ops#/var/lib/conector/central-ops#g' /usr/local/sbin/conector-central-ops || true
  chmod 755 /usr/local/sbin/conector-central-ops

  cat >/etc/systemd/system/conector-central-ops.service <<'EOF'
[Unit]
Description=Conector Central operations runner
After=network-online.target conector-sync.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/conector-central-ops
EOF

  cat >/etc/systemd/system/conector-central-ops.timer <<'EOF'
[Unit]
Description=Run Conector Central operations

[Timer]
OnBootSec=20
OnUnitActiveSec=30
AccuracySec=5
Persistent=true

[Install]
WantedBy=timers.target
EOF
fi

systemctl daemon-reload
systemctl enable --now conector-sync.timer

if [ -f /etc/systemd/system/conector-central-ops.timer ]; then
  systemctl enable --now conector-central-ops.timer
fi

{
  echo "CONECTOR_MIGRATION_V2"
  echo "date=$(date -Is)"
  echo "conector_sync=$(systemctl is-active conector-sync.timer 2>/dev/null || true)"
  echo "conector_ops=$(systemctl is-active conector-central-ops.timer 2>/dev/null || true)"
  echo "legacy_sync=$(systemctl is-active corex-sync.timer 2>/dev/null || true)"
  echo "legacy_ops=$(systemctl is-active corex-central-ops.timer 2>/dev/null || true)"
} >/tmp/conector-migration-v2.txt

echo "CONECTOR_MIGRATION_V2_OK"
