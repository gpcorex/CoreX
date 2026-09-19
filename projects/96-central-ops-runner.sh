#!/usr/bin/env bash
set -euo pipefail
TASK_DIR="/opt/corex/repo/central-ops"
STATE_DIR="/var/lib/corex/central-ops"
RESULT_DIR="/srv/apps/android-bridge/www/corex-results"
RUNNER="/usr/local/sbin/corex-central-ops"
mkdir -p "$TASK_DIR" "$STATE_DIR" "$RESULT_DIR"
cat >"$RUNNER" <<'EOF'
#!/usr/bin/env bash
set -u
TASK_DIR="/opt/corex/repo/central-ops"
STATE_DIR="/var/lib/corex/central-ops"
RESULT_DIR="/srv/apps/android-bridge/www/corex-results"
INDEX="$RESULT_DIR/index.txt"
LOCK="/run/corex-central-ops.lock"
mkdir -p "$STATE_DIR" "$RESULT_DIR"
exec 9>"$LOCK"
flock -n 9 || exit 0
while IFS= read -r -d '' task; do
  base="$(basename "$task")"
  stem="$(basename "$task" .sh)"
  hash="$(sha256sum "$task" | awk '{print $1}')"
  mark="$STATE_DIR/$base.sha256"
  out="$RESULT_DIR/$stem.txt"
  old=""
  [ -f "$mark" ] && old="$(cat "$mark" 2>/dev/null || true)"
  [ "$old" = "$hash" ] && continue
  tmp="$(mktemp)"
  {
    echo "COREX_TASK_RESULT"
    echo "task=$base"
    echo "started_at=$(date -Is)"
    echo "repo_head=$(git -C /opt/corex/repo rev-parse HEAD 2>/dev/null || true)"
    echo
  } >"$tmp"
  set +e
  bash "$task" >>"$tmp" 2>&1
  rc=$?
  set -e
  {
    echo
    echo "exit_code=$rc"
    echo "finished_at=$(date -Is)"
  } >>"$tmp"
  mv "$tmp" "$out"
  chmod 644 "$out"
  echo "$hash" >"$mark"
done < <(find "$TASK_DIR" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null | sort -z)
{
  echo "COREX_RESULTS"
  echo "generated_at=$(date -Is)"
  find "$RESULT_DIR" -maxdepth 1 -type f -name '*.txt' -printf '%f\n' | sort
} >"$INDEX"
chmod 644 "$INDEX"
EOF
chmod 755 "$RUNNER"
cat >/etc/systemd/system/corex-central-ops.service <<'EOF'
[Unit]
Description=CoreX Central operations runner
After=network-online.target corex-sync.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/corex-central-ops
EOF
cat >/etc/systemd/system/corex-central-ops.timer <<'EOF'
[Unit]
Description=Run CoreX Central operations
[Timer]
OnBootSec=20
OnUnitActiveSec=30
AccuracySec=5
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now corex-central-ops.timer
systemctl start corex-central-ops.service || true
echo "COREX_CENTRAL_OPS_READY"
