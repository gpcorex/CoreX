#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/gpcorex/CoreX.git"
BASE="/opt/corex"
STATE="/var/lib/corex"
LOG="/var/log/corex"
ETC="/etc/corex"

if [ "$(id -u)" -ne 0 ]; then
  echo "Ejecutar con sudo: sudo bash bootstrap.sh"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git curl ca-certificates rsync

mkdir -p "$BASE" "$STATE" "$LOG" "$ETC" /srv/apps
chmod 700 "$ETC"

if [ ! -d "$BASE/repo/.git" ]; then
  rm -rf "$BASE/repo"
  git clone "$REPO_URL" "$BASE/repo"
else
  git -C "$BASE/repo" fetch origin main
  git -C "$BASE/repo" reset --hard origin/main
fi

cat >/usr/local/sbin/corex-sync <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/corex/repo"
LOCK="/run/corex-sync.lock"
LOG="/var/log/corex/sync.log"

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

  echo "$REMOTE" >/var/lib/corex/last_deployed_commit
  echo "Deploy OK."
} >>"$LOG" 2>&1
EOF

chmod 755 /usr/local/sbin/corex-sync

cat >/etc/systemd/system/corex-sync.service <<'EOF'
[Unit]
Description=CoreX deployment sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/corex-sync
EOF

cat >/etc/systemd/system/corex-sync.timer <<'EOF'
[Unit]
Description=Run CoreX sync every minute

[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=5
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now corex-sync.timer

echo
echo "COREX_BOOTSTRAP_OK"
echo "Repo: $BASE/repo"
echo "Apps: /srv/apps"
echo "Secrets: $ETC"
echo "Log: $LOG/sync.log"
systemctl --no-pager status corex-sync.timer || true
