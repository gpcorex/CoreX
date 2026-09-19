#!/usr/bin/env bash
set -euo pipefail

APP="/srv/apps/android-bridge"
mkdir -p "$APP"/{www,apks,data}
chmod 755 "$APP"

cat >"$APP/server.py" <<'PY'
#!/usr/bin/env python3
import json, os, platform, shutil, socket, subprocess
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse

ROOT = "/srv/apps/android-bridge"
WWW = os.path.join(ROOT, "www")
APKS = os.path.join(ROOT, "apks")
PORT = 8787

class Handler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        path = urlparse(path).path
        if path == "/":
            path = "/index.html"
        return os.path.join(WWW, path.lstrip("/"))

    def do_GET(self):
        if self.path == "/api/status":
            data = {
                "ok": True,
                "service": "Android Bridge",
                "host": socket.gethostname(),
                "arch": platform.machine(),
                "cpus": os.cpu_count(),
                "kvm": os.path.exists("/dev/kvm"),
                "android_runtime": False,
                "phase": "base_ready",
                "apk_count": len([x for x in os.listdir(APKS) if x.lower().endswith((".apk",".xapk",".apks"))]),
            }
            raw = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if self.path == "/api/apks":
            items = sorted([x for x in os.listdir(APKS) if x.lower().endswith((".apk",".xapk",".apks"))])
            raw = json.dumps({"items":items}).encode()
            self.send_response(200)
            self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        super().do_GET()

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

if __name__ == "__main__":
    os.chdir(WWW)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PY

cat >"$APP/www/index.html" <<'HTML'
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Android Bridge</title>
<style>
body{font-family:system-ui,sans-serif;background:#111;color:#eee;margin:0;padding:24px}
main{max-width:820px;margin:auto}
.card{background:#1b1b1b;border:1px solid #333;border-radius:16px;padding:20px;margin:16px 0}
h1{margin-top:0}
.ok{color:#7CFC8A}.warn{color:#FFD166}
code{background:#222;padding:3px 6px;border-radius:6px}
small{color:#aaa}
</style>
</head>
<body>
<main>
<h1>Android Bridge</h1>
<div class="card">
  <h2>Estado</h2>
  <div id="status">Consultando…</div>
</div>
<div class="card">
  <h2>Aplicaciones</h2>
  <div id="apps">Sin datos</div>
</div>
<div class="card">
  <h2>Etapa actual</h2>
  <p class="warn">Base instalada. El runtime Android todavía no está activado.</p>
  <small>La VM tiene KVM, pero por ahora conservamos memoria para Central y los demás servicios.</small>
</div>
</main>
<script>
async function load(){
  try{
    const s=await (await fetch('/api/status')).json();
    document.getElementById('status').innerHTML =
      '<span class="ok">● Online</span><br>'+
      'Host: <code>'+s.host+'</code><br>'+
      'Arquitectura: <code>'+s.arch+'</code><br>'+
      'CPU: <code>'+s.cpus+'</code><br>'+
      'KVM: <code>'+(s.kvm?'Sí':'No')+'</code><br>'+
      'Runtime Android: <code>'+(s.android_runtime?'Activo':'Pendiente')+'</code>';
    const a=await (await fetch('/api/apks')).json();
    document.getElementById('apps').textContent = a.items.length ? a.items.join(', ') : 'Todavía no hay APK cargados.';
  }catch(e){
    document.getElementById('status').textContent='Sin conexión con el servicio';
  }
}
load(); setInterval(load,10000);
</script>
</body>
</html>
HTML

cat >/etc/systemd/system/android-bridge.service <<'UNIT'
[Unit]
Description=Android Bridge base service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /srv/apps/android-bridge/server.py
Restart=always
RestartSec=2
User=ubuntu
Group=ubuntu
WorkingDirectory=/srv/apps/android-bridge

[Install]
WantedBy=multi-user.target
UNIT

chown -R ubuntu:ubuntu "$APP"
chmod 755 "$APP/server.py"

systemctl daemon-reload
systemctl enable --now android-bridge.service

sleep 1
curl -fsS http://127.0.0.1:8787/api/status >"$APP/data/status.json"

echo "ANDROID_BRIDGE_BASE_OK"
