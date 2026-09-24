#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center/video"
SERVICE="$BASE/catalog_service.py"
OUT="/var/lib/conector/media-catalog-service-v1.txt"
UNIT="/etc/systemd/system/media-catalog.service"
mkdir -p "$BASE" /var/lib/conector

cat > "$SERVICE" <<'PY'
#!/usr/bin/env python3
import json
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

DB = "/home/ubuntu/Central/media_center/video/catalog.db"
HOST = "127.0.0.1"
PORT = 8092

def db():
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    return conn

def rows(sql, params=()):
    conn = db()
    try:
        return [dict(r) for r in conn.execute(sql, params).fetchall()]
    finally:
        conn.close()

class Handler(BaseHTTPRequestHandler):
    server_version = "MediaCatalog/1.0"

    def send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)

        if u.path == "/health":
            try:
                conn = db()
                count = conn.execute("SELECT count(*) FROM video_item").fetchone()[0]
                live = conn.execute("SELECT count(*) FROM live_channel").fetchone()[0]
                conn.close()
                self.send_json(200, {"ok": True, "video_items": count, "live_channels": live})
            except Exception as e:
                self.send_json(500, {"ok": False, "error": str(e)})
            return

        if u.path == "/video/items":
            limit = min(max(int(q.get("limit", ["50"])[0]), 1), 200)
            kind = q.get("kind", [None])[0]
            if kind:
                data = rows(
                    """SELECT v.*, 
                              (SELECT url FROM image i WHERE i.video_item_id=v.id ORDER BY priority DESC,id LIMIT 1) AS poster_url
                       FROM video_item v
                       WHERE v.kind=?
                       ORDER BY v.updated_at DESC
                       LIMIT ?""",
                    (kind, limit)
                )
            else:
                data = rows(
                    """SELECT v.*, 
                              (SELECT url FROM image i WHERE i.video_item_id=v.id ORDER BY priority DESC,id LIMIT 1) AS poster_url
                       FROM video_item v
                       ORDER BY v.updated_at DESC
                       LIMIT ?""",
                    (limit,)
                )
            self.send_json(200, {"items": data, "count": len(data)})
            return

        if u.path == "/video/search":
            term = q.get("q", [""])[0].strip()
            limit = min(max(int(q.get("limit", ["50"])[0]), 1), 200)
            if not term:
                self.send_json(200, {"items": [], "count": 0})
                return
            like = "%" + term + "%"
            data = rows(
                """SELECT v.*,
                          (SELECT url FROM image i WHERE i.video_item_id=v.id ORDER BY priority DESC,id LIMIT 1) AS poster_url
                   FROM video_item v
                   WHERE v.title LIKE ? COLLATE NOCASE
                      OR COALESCE(v.original_title,'') LIKE ? COLLATE NOCASE
                      OR COALESCE(v.description,'') LIKE ? COLLATE NOCASE
                   ORDER BY v.title
                   LIMIT ?""",
                (like, like, like, limit)
            )
            self.send_json(200, {"items": data, "count": len(data), "query": term})
            return

        if u.path.startswith("/video/item/"):
            item_id = u.path.split("/video/item/", 1)[1]
            base = rows("SELECT * FROM video_item WHERE id=?", (item_id,))
            if not base:
                self.send_json(404, {"error": "not_found"})
                return
            payload = base[0]
            payload["images"] = rows("SELECT image_type,url,language,provider,priority FROM image WHERE video_item_id=? ORDER BY priority DESC,id", (item_id,))
            payload["tags"] = rows("""SELECT t.name FROM tag t JOIN video_item_tag vit ON vit.tag_id=t.id WHERE vit.video_item_id=? ORDER BY t.name""", (item_id,))
            payload["seasons"] = rows("SELECT id,season_number,title,description FROM season WHERE video_item_id=? ORDER BY season_number", (item_id,))
            for s in payload["seasons"]:
                s["episodes"] = rows("SELECT id,external_program_id,episode_number,title,description,duration_seconds,quality_hint,viewpoint FROM episode WHERE season_id=? ORDER BY episode_number", (s["id"],))
            self.send_json(200, payload)
            return

        if u.path == "/live/channels":
            data = rows("SELECT * FROM live_channel ORDER BY COALESCE(channel_number,999999), name")
            self.send_json(200, {"channels": data, "count": len(data)})
            return

        if u.path.startswith("/live/channel/") and u.path.endswith("/epg"):
            channel_id = u.path[len("/live/channel/"):-len("/epg")].rstrip("/")
            data = rows("SELECT * FROM epg_program WHERE channel_id=? ORDER BY starts_at", (channel_id,))
            self.send_json(200, {"channel_id": channel_id, "programs": data, "count": len(data)})
            return

        self.send_json(404, {"error": "not_found"})

def main():
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()

if __name__ == "__main__":
    main()
PY

chmod 755 "$SERVICE"

cat > "$UNIT" <<EOF
[Unit]
Description=Centro Multimedia Video Catalog API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
ExecStart=/usr/bin/python3 $SERVICE
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

chown ubuntu:ubuntu "$SERVICE"
systemctl daemon-reload
systemctl enable --now media-catalog.service
sleep 1

HEALTH="$(curl -fsS http://127.0.0.1:8092/health)"
ITEMS="$(curl -fsS 'http://127.0.0.1:8092/video/items?limit=5')"
LIVE="$(curl -fsS http://127.0.0.1:8092/live/channels)"
STATUS="$(systemctl is-active media-catalog.service)"

{
  echo "MEDIA_CATALOG_SERVICE_V1_READY"
  echo "service_status=$STATUS"
  echo "listen=127.0.0.1:8092"
  echo "health=$HEALTH"
  echo "sample_items=$ITEMS"
  echo "sample_live=$LIVE"
  echo "service=$SERVICE"
  echo "unit=$UNIT"
} > "$OUT"

chmod 600 "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-catalog-service-v1.txt" || true
fi

echo "MEDIA_CATALOG_SERVICE_V1_READY"
