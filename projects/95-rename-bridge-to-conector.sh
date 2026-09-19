#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/corex/repo"
STATE="/var/lib/conector"
LOG="/var/log/conector"
mkdir -p "$STATE" "$LOG"

# Nuevo comando de sincronización. Mantiene /opt/corex/repo como ruta física del repo
# para no romper el mecanismo que está ejecutando esta misma migración.
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
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=5
Persistent=true
[Install]
WantedBy=timers.target
EOF

# Renombra el runner operativo de Central.
if [ -f /usr/local/sbin/corex-central-ops ]; then
  cp -a /usr/local/sbin/corex-central-ops /usr/local/sbin/conector-central-ops
  sed -i 's#/var/lib/corex/central-ops#/var/lib/conector/central-ops#g' /usr/local/sbin/conector-central-ops
fi

if [ -f /usr/local/sbin/conector-central-ops ]; then
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

# Compatibilidad temporal: el circuito viejo deja de programarse, pero no se borra todavía.
systemctl disable --now corex-sync.timer 2>/dev/null || true
systemctl disable --now corex-central-ops.timer 2>/dev/null || true

# Alias de compatibilidad durante la transición.
ln -sfn /usr/local/sbin/conector-sync /usr/local/sbin/corex-sync
if [ -f /usr/local/sbin/conector-central-ops ]; then
  ln -sfn /usr/local/sbin/conector-central-ops /usr/local/sbin/corex-central-ops
fi

cat >/srv/apps/android-bridge/www/conector-status.txt <<EOF
CONECTOR_RENAME_OK
date=$(date -Is)
repo_physical_path=/opt/corex/repo
sync_timer=$(systemctl is-active conector-sync.timer 2>/dev/null || true)
ops_timer=$(systemctl is-active conector-central-ops.timer 2>/dev/null || true)
legacy_sync_timer=$(systemctl is-active corex-sync.timer 2>/dev/null || true)
legacy_ops_timer=$(systemctl is-active corex-central-ops.timer 2>/dev/null || true)
EOF
chmod 644 /srv/apps/android-bridge/www/conector-status.txt

echo "CONECTOR_RENAME_OK"
