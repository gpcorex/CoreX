#!/usr/bin/env bash
set -euo pipefail

APP="/srv/apps/conector"
WWW="$APP/www"
PORT=8790
mkdir -p "$WWW"

cat >"$APP/server.py" <<'PY'
#!/usr/bin/env python3
import os, json, socket
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse

ROOT="/srv/apps/conector/www"
PORT=8790

class Handler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        p=urlparse(path).path
        if p=="/": p="/index.html"
        return os.path.join(ROOT,p.lstrip("/"))

    def do_GET(self):
        if self.path=="/api/status":
            raw=json.dumps({
                "ok": True,
                "service": "Conector",
                "host": socket.gethostname()
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type","application/json")
            self.send_header("Cache-Control","no-store")
            self.send_header("Content-Length",str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        super().do_GET()

    def log_message(self, fmt, *args):
        pass

os.chdir(ROOT)
ThreadingHTTPServer(("127.0.0.1",PORT),Handler).serve_forever()
PY

cat >"$WWW/index.html" <<'EOF'
<!doctype html><meta charset="utf-8"><title>Conector</title><h1>Conector</h1><p>Online</p>
EOF

cat >/etc/systemd/system/conector-api.service <<EOF
[Unit]
Description=Conector result API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $APP/server.py
Restart=always
RestartSec=2
User=ubuntu
Group=ubuntu
WorkingDirectory=$APP

[Install]
WantedBy=multi-user.target
EOF

chown -R ubuntu:ubuntu "$APP"
chmod 755 "$APP/server.py"
systemctl daemon-reload
systemctl enable --now conector-api.service

CADDY="/etc/caddy/Caddyfile"
cp -a "$CADDY" "$CADDY.before-conector"

if ! grep -q 'route /conector/\\*' "$CADDY"; then
python3 - <<'PY'
from pathlib import Path
p=Path("/etc/caddy/Caddyfile")
s=p.read_text()
needle="""    route {
        reverse_proxy 127.0.0.1:8090
    }
"""
insert="""    route /conector/* {
        uri strip_prefix /conector
        reverse_proxy 127.0.0.1:8790
    }

"""
if needle not in s:
    raise SystemExit("catch-all route not found")
p.write_text(s.replace(needle,insert+needle,1))
PY
fi

caddy validate --config "$CADDY"
systemctl reload caddy

mkdir -p "$WWW/results"
cat >"$WWW/results/health.txt" <<EOF
CONECTOR_OK
generated_at=$(date -Is)
conector_sync=$(systemctl is-active conector-sync.timer 2>/dev/null || true)
conector_ops=$(systemctl is-active conector-central-ops.timer 2>/dev/null || true)
legacy_sync=$(systemctl is-active corex-sync.timer 2>/dev/null || true)
legacy_ops=$(systemctl is-active corex-central-ops.timer 2>/dev/null || true)
central_backend=$(systemctl is-active central-backend 2>/dev/null || true)
EOF

echo "CONECTOR_RESULT_CHANNEL_READY"
