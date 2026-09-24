#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center"
VIDEO="$BASE/video"
XUPER="$VIDEO/adapters/xuper"
INBOX="$BASE/inbox/xuper"
PROCESSED="$BASE/processed/xuper"
FAILED="$BASE/failed/xuper"
OUT="/var/lib/conector/media-xuper-inbox-v1-fix.txt"

mkdir -p "$INBOX" "$PROCESSED" "$FAILED" /var/lib/conector

cat > "$XUPER/process_inbox.py" <<'PY'
#!/usr/bin/env python3
import json, os, shutil, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

BASE = Path("/home/ubuntu/Central/media_center")
INBOX = BASE / "inbox" / "xuper"
PROCESSED = BASE / "processed" / "xuper"
FAILED = BASE / "failed" / "xuper"
INGEST = BASE / "video" / "adapters" / "xuper" / "ingest_xuper.py"
DB = Path(os.environ.get("MEDIA_CATALOG_DB", str(BASE / "video" / "catalog.db")))

def stamp():
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")

def move_with_stamp(src, target_dir):
    target_dir.mkdir(parents=True, exist_ok=True)
    dst = target_dir / f"{stamp()}-{src.name}"
    shutil.move(str(src), str(dst))
    return dst

def process_one(src):
    p = subprocess.run(
        [sys.executable, str(INGEST), str(src), "--db", str(DB)],
        text=True, capture_output=True
    )
    if p.returncode == 0:
        dst = move_with_stamp(src, PROCESSED)
        return {"file": src.name, "ok": True, "moved_to": str(dst), "result": p.stdout.strip()}
    dst = move_with_stamp(src, FAILED)
    return {"file": src.name, "ok": False, "moved_to": str(dst), "error": (p.stderr or p.stdout).strip()}

def main():
    INBOX.mkdir(parents=True, exist_ok=True)
    files = sorted(p for p in INBOX.glob("*.json") if p.is_file())
    results = []
    for p in files:
        if p.exists():
            results.append(process_one(p))
    payload = {"ok": all(x["ok"] for x in results), "processed": len(results), "db": str(DB), "results": results}
    print(json.dumps(payload, ensure_ascii=False))
    return 0 if payload["ok"] else 1

if __name__ == "__main__":
    raise SystemExit(main())
PY

chmod 755 "$XUPER/process_inbox.py"

cat > /etc/systemd/system/media-xuper-inbox.service <<EOF
[Unit]
Description=Process Xuper media inbox
After=media-catalog.service

[Service]
Type=oneshot
User=ubuntu
Group=ubuntu
Environment=MEDIA_CATALOG_DB=$VIDEO/catalog.db
ExecStart=/usr/bin/python3 $XUPER/process_inbox.py
EOF

cat > /etc/systemd/system/media-xuper-inbox.path <<EOF
[Unit]
Description=Watch Xuper media inbox

[Path]
PathExistsGlob=$INBOX/*.json
Unit=media-xuper-inbox.service

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl stop media-xuper-inbox.path 2>/dev/null || true
systemctl stop media-xuper-inbox.service 2>/dev/null || true

chown ubuntu:ubuntu "$VIDEO/catalog.db"
rm -f "$VIDEO/catalog.db-wal" "$VIDEO/catalog.db-shm"
sqlite3 "$VIDEO/catalog.db" "PRAGMA foreign_keys=ON; DELETE FROM video_item WHERE id IN ('xuper:fixture-movie-001','xuper:fixture-series-001'); DELETE FROM live_channel WHERE id IN ('xuper-live:ch-001','xuper-live:ch-002'); DELETE FROM tag WHERE id NOT IN (SELECT tag_id FROM video_item_tag);"

rm -f "$INBOX"/*.json
rm -f "$PROCESSED"/*test-vod.json "$PROCESSED"/*test-live.json 2>/dev/null || true
rm -f "$FAILED"/*test-vod.json "$FAILED"/*test-live.json 2>/dev/null || true

TESTDB="/tmp/xuper-inbox-v1-fix-test.db"
rm -f "$TESTDB" "$TESTDB-wal" "$TESTDB-shm"
sqlite3 "$TESTDB" < "$VIDEO/schema.sql"
chown ubuntu:ubuntu "$TESTDB"

cp "$XUPER/fixture_v2.json" "$INBOX/test-vod.json"
cp "$XUPER/fixture_live_v1.json" "$INBOX/test-live.json"
chown ubuntu:ubuntu "$INBOX/test-vod.json" "$INBOX/test-live.json"

TEST_RESULT="$(sudo -u ubuntu env MEDIA_CATALOG_DB="$TESTDB" /usr/bin/python3 "$XUPER/process_inbox.py")"

ITEMS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM video_item;")"
EPISODES="$(sqlite3 "$TESTDB" "SELECT count(*) FROM episode;")"
CHANNELS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM live_channel;")"
EPG="$(sqlite3 "$TESTDB" "SELECT count(*) FROM epg_program;")"
FK="$(sqlite3 "$TESTDB" "PRAGMA foreign_key_check;")"

[ "$ITEMS" = "2" ]
[ "$EPISODES" = "2" ]
[ "$CHANNELS" = "2" ]
[ "$EPG" = "3" ]

systemctl enable --now media-xuper-inbox.path
PATH_STATUS="$(systemctl is-active media-xuper-inbox.path)"
REAL_HEALTH="$(curl -fsS http://127.0.0.1:8092/health)"

{
  echo "MEDIA_XUPER_INBOX_V1_FIX_READY"
  echo "path_status=$PATH_STATUS"
  echo "test_result=$TEST_RESULT"
  echo "test_video_item_count=$ITEMS"
  echo "test_episode_count=$EPISODES"
  echo "test_live_channel_count=$CHANNELS"
  echo "test_epg_program_count=$EPG"
  echo "foreign_key_check=${FK:-OK}"
  echo "real_health=$REAL_HEALTH"
  echo "inbox=$INBOX"
  echo "processed=$PROCESSED"
  echo "failed=$FAILED"
} > "$OUT"

chmod 600 "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-xuper-inbox-v1-fix.txt" || true
fi

echo "MEDIA_XUPER_INBOX_V1_FIX_READY"
