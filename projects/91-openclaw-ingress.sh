#!/usr/bin/env bash
set -euo pipefail

# Deploy runs non-interactively; OpenClaw expects HOME to exist.
export HOME="/home/ubuntu"

OPENCLAW_USER="ubuntu"
OPENCLAW_HOME="/home/ubuntu"
CONF_DIR="$OPENCLAW_HOME/.openclaw"
CONF="$CONF_DIR/openclaw.json"
ENV_DIR="/etc/conector"
ENV_FILE="$ENV_DIR/openclaw.env"
PORT="18789"
DOMAIN="https://cen-tral.duckdns.org"

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$ENV_DIR"
chmod 700 "$ENV_DIR"

OPENCLAW_BIN="$(command -v openclaw || true)"
if [ -z "$OPENCLAW_BIN" ]; then
  for p in /home/ubuntu/.npm-global/bin/openclaw /usr/local/bin/openclaw /usr/bin/openclaw /home/ubuntu/.local/bin/openclaw; do
    [ -x "$p" ] && OPENCLAW_BIN="$p" && break
  done
fi
[ -n "$OPENCLAW_BIN" ] || { echo "OPENCLAW_BIN_NOT_FOUND_NO_INSTALL"; exit 1; }

if [ ! -s "$ENV_FILE" ]; then
  TOKEN="$(openssl rand -hex 32)"
  printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "$TOKEN" >"$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

install -d -o "$OPENCLAW_USER" -g "$OPENCLAW_USER" "$CONF_DIR"
cat >"$CONF" <<EOF
{
  "gateway": {
    "mode": "local",
    "port": $PORT,
    "bind": "loopback",
    "publicOrigin": "$DOMAIN",
    "auth": {
      "mode": "token",
      "rateLimit": {
        "maxAttempts": 10,
        "windowMs": 60000,
        "lockoutMs": 300000,
        "exemptLoopback": true
      }
    },
    "controlUi": {
      "enabled": true,
      "basePath": "/openclaw",
      "allowedOrigins": ["$DOMAIN"]
    },
    "terminal": {
      "enabled": false
    }
  }
}
EOF
chown "$OPENCLAW_USER:$OPENCLAW_USER" "$CONF"
chmod 600 "$CONF"

cat >/etc/systemd/system/openclaw-gateway.service <<EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=simple
User=$OPENCLAW_USER
Group=$OPENCLAW_USER
EnvironmentFile=$ENV_FILE
Environment=HOME=$OPENCLAW_HOME
Environment=OPENCLAW_NO_RESPAWN=1
Environment=NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache
ExecStart=$OPENCLAW_BIN gateway --port $PORT
Restart=always
RestartSec=5
RestartPreventExitStatus=78
TimeoutStartSec=90
TimeoutStopSec=30
SuccessExitStatus=0 143
OOMPolicy=continue
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/tmp/openclaw-compile-cache
chown "$OPENCLAW_USER:$OPENCLAW_USER" /var/tmp/openclaw-compile-cache

CADDY="/etc/caddy/Caddyfile"
if [ -f "$CADDY" ]; then
  cp -a "$CADDY" "$CADDY.before-openclaw"
  if ! grep -q 'route /openclaw/\\*' "$CADDY"; then
    python3 - <<'PY'
from pathlib import Path
p=Path("/etc/caddy/Caddyfile")
s=p.read_text()
needle="""    route {
        reverse_proxy 127.0.0.1:8090
    }
"""
insert="""    route /openclaw/* {
        reverse_proxy 127.0.0.1:18789
    }

"""
if needle not in s:
    raise SystemExit("No se encontró catch-all esperado en Caddyfile")
p.write_text(s.replace(needle, insert + needle, 1))
PY
  fi
  caddy validate --config "$CADDY"
fi

systemctl daemon-reload
systemctl enable --now openclaw-gateway.service
sleep 3

if [ -f "$CADDY" ]; then
  systemctl reload caddy
fi

mkdir -p /var/lib/conector
cat >/var/lib/conector/write-authority <<'EOF'
openclaw
EOF
chmod 600 /var/lib/conector/write-authority

{
  echo "OPENCLAW_INSTALL_STATUS"
  echo "date=$(date -Is)"
  echo "binary=$OPENCLAW_BIN"
  echo "version=$($OPENCLAW_BIN --version 2>/dev/null || true)"
  echo "gateway=$(systemctl is-active openclaw-gateway.service 2>/dev/null || true)"
  echo "listen=$(ss -ltn 2>/dev/null | grep -c ':18789 ' || true)"
  echo "write_authority=$(cat /var/lib/conector/write-authority)"
  echo "public_path=$DOMAIN/openclaw/"
} >/var/lib/conector/openclaw-status.txt

cat /var/lib/conector/openclaw-status.txt
