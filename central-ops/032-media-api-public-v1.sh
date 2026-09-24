#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/media-api-public-v1.txt"
CADDYFILE="/etc/caddy/Caddyfile"
BACKUP="/etc/caddy/Caddyfile.media-api-backup"
PUBLIC_BASE="https://cen-tral.duckdns.org"
ROUTE="/media-api"

mkdir -p /var/lib/conector

cp "$CADDYFILE" "$BACKUP"

python3 - <<'PY'
from pathlib import Path
p = Path("/etc/caddy/Caddyfile")
s = p.read_text(encoding="utf-8")

marker = "# MEDIA_CATALOG_API_V1"
block = """
    # MEDIA_CATALOG_API_V1
    handle_path /media-api/* {
        reverse_proxy 127.0.0.1:8092
    }
"""

if marker not in s:
    idx = s.rfind("}")
    if idx < 0:
        raise SystemExit("CADDY_ROOT_BLOCK_NOT_FOUND")
    s = s[:idx] + block + "\n" + s[idx:]
    p.write_text(s, encoding="utf-8")
PY

caddy validate --config "$CADDYFILE"
systemctl reload caddy
sleep 1

LOCAL_HEALTH="$(curl -fsS http://127.0.0.1:8092/health)"
PUBLIC_HEALTH="$(curl -fsS "$PUBLIC_BASE$ROUTE/health")"

{
  echo "MEDIA_API_PUBLIC_V1_READY"
  echo "local_health=$LOCAL_HEALTH"
  echo "public_health=$PUBLIC_HEALTH"
  echo "public_base=$PUBLIC_BASE$ROUTE"
  echo "caddyfile=$CADDYFILE"
  echo "backup=$BACKUP"
} > "$OUT"

chmod 600 "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-api-public-v1.txt" || true
fi

echo "MEDIA_API_PUBLIC_V1_READY"
