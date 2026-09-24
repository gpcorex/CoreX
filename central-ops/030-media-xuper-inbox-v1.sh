#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center"
VIDEO="$BASE/video"
XUPER="$VIDEO/adapters/xuper"
INBOX="$BASE/inbox/xuper"
PROCESSED="$BASE/processed/xuper"
FAILED="$BASE/failed/xuper"
OUT="/var/lib/conector/media-xuper-inbox-v1.txt"

mkdir -p "$INBOX" "$PROCESSED" "$FAILED" /var/lib/conector

cat > "$XUPER/process_inbox.py" <<'PY'
#!/usr/bin/env python3
import json, shutil, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

BASE = Path("/home/ubuntu/Central/media_center")
INBOX = BASE / "inbox" / "xuper"
PROCESSED = BASE / "processed" / "xuper"
FAILED = BASE / "failed" / "xuper"
INGEST = BASE / "video" / "adapters" / "xuper" / "ingest_xuper.py"
DB = BASE / "video" / "catalog.db"

def stamp():
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

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
    results = [process_one(p) for p in files]
    print(json.dumps({"ok": all(x["ok"] for x in results), "processed": len(results), "results": results}, ensure_ascii=False))
    return 0 if all(x["ok"] for x in results) else 1

if __name__ == "__main__":
    raise SystemExit(main())
PY

chmod 755 "$XUPER/process_inbox.py"

cat > /etc/systemd/system/media-xuper-inbox.service <<EOF
[Unit]
Description=Process Xuper media inbox

[Service]
Type=oneshot
User=ubuntu
Group=ubuntu
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
systemctl enable --now media-xuper-inbox.path

rm -f "$INBOX"/*.json
cp "$XUPER/fixture_v2.json" "$INBOX/test-vod.json"
cp "$XUPER/fixture_live_v1.json" "$INBOX/test-live.json"

sudo -u ubuntu /usr/bin/python3 "$XUPER/process_inbox.py" >/tmp/media-xuper-inbox-test.json

HEALTH="$(curl -fsS http://127.0.0.1:8092/health)"
ITEMS="$(sqlite3 "$VIDEO/catalog.db" "SELECT count(*) FROM video_item;")"
CHANNELS="$(sqlite3 "$VIDEO/catalog.db" "SELECT count(*) FROM live_channel;")"
EPISODES="$(sqlite3 "$VIDEO/catalog.db" "SELECT count(*) FROM episode;")"
EPG="$(sqlite3 "$VIDEO/catalog.db" "SELECT count(*) FROM epg_program;")"
PATH_STATUS="$(systemctl is-active media-xuper-inbox.path)"
SERVICE_RESULT="$(cat /tmp/media-xuper-inbox-test.json)"

{
  echo "MEDIA_XUPER_INBOX_V1_READY"
  echo "path_status=$PATH_STATUS"
  echo "service_result=$SERVICE_RESULT"
  echo "health=$HEALTH"
  echo "video_item_count=$ITEMS"
  echo "episode_count=$EPISODES"
  echo "live_channel_count=$CHANNELS"
  echo "epg_program_count=$EPG"
  echo "inbox=$INBOX"
  echo "processed=$PROCESSED"
  echo "failed=$FAILED"
} > "$OUT"

chmod 600 "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-xuper-inbox-v1.txt" || true
fi

echo "MEDIA_XUPER_INBOX_V1_READY"
