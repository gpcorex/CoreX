#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center"
VIDEO="$BASE/video"
XUPER="$VIDEO/adapters/xuper"
INBOX="$BASE/inbox/xuper"
ARCHIVE="$BASE/archive/xuper"
OUT="/var/lib/conector/media-xuper-ingest-v1-fix.txt"
mkdir -p "$INBOX" "$ARCHIVE" /var/lib/conector

cat > "$XUPER/ingest_xuper.py" <<'PY'
#!/usr/bin/env python3
import argparse, json, shutil, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

BASE = Path("/home/ubuntu/Central/media_center")
VIDEO = BASE / "video"
XUPER = VIDEO / "adapters" / "xuper"
DB = VIDEO / "catalog.db"
ARCHIVE = BASE / "archive" / "xuper"

def run(cmd):
    p = subprocess.run(cmd, text=True, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout).strip())
    return p.stdout.strip()

def has_key(node, wanted):
    if isinstance(node, dict):
        if wanted in node:
            return True
        return any(has_key(v, wanted) for v in node.values())
    if isinstance(node, list):
        return any(has_key(v, wanted) for v in node)
    return False

def classify(data):
    kinds = []
    if has_key(data, "assetList") or has_key(data, "simpleProgramList"):
        kinds.append("vod")
    if has_key(data, "channelList") or has_key(data, "channelCode") or has_key(data, "programList"):
        kinds.append("live")
    return kinds

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json_file")
    ap.add_argument("--db", default=str(DB))
    ap.add_argument("--no-archive", action="store_true")
    args = ap.parse_args()

    src = Path(args.json_file)
    data = json.loads(src.read_text(encoding="utf-8"))
    kinds = classify(data)
    if not kinds:
        raise SystemExit("UNSUPPORTED_XUPER_PAYLOAD")

    results = []
    if "vod" in kinds:
        out = run([sys.executable, str(XUPER / "import_xuper.py"), str(src), "--db", args.db])
        results.append({"kind":"vod","result":json.loads(out)})
    if "live" in kinds:
        out = run([sys.executable, str(XUPER / "import_xuper_live.py"), str(src), "--db", args.db])
        results.append({"kind":"live","result":json.loads(out)})

    archived = None
    if not args.no_archive:
        ARCHIVE.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        archived = ARCHIVE / f"{stamp}-{src.name}"
        shutil.copy2(src, archived)

    print(json.dumps({
        "ok": True,
        "source": str(src),
        "classified_as": kinds,
        "results": results,
        "archived": str(archived) if archived else None
    }, ensure_ascii=False))

if __name__ == "__main__":
    main()
PY

chmod 755 "$XUPER/ingest_xuper.py"

TESTDB="/tmp/xuper-ingest-v1-fix-test.db"
rm -f "$TESTDB"
sqlite3 "$TESTDB" < "$VIDEO/schema.sql"

cp "$XUPER/fixture_v2.json" "$INBOX/vod-fixture.json"
cp "$XUPER/fixture_live_v1.json" "$INBOX/live-fixture.json"

VOD="$(python3 "$XUPER/ingest_xuper.py" "$INBOX/vod-fixture.json" --db "$TESTDB" --no-archive)"
LIVE="$(python3 "$XUPER/ingest_xuper.py" "$INBOX/live-fixture.json" --db "$TESTDB" --no-archive)"

ITEMS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM video_item;")"
EPISODES="$(sqlite3 "$TESTDB" "SELECT count(*) FROM episode;")"
CHANNELS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM live_channel;")"
EPG="$(sqlite3 "$TESTDB" "SELECT count(*) FROM epg_program;")"
FK="$(sqlite3 "$TESTDB" "PRAGMA foreign_key_check;")"

[ "$ITEMS" = "2" ]
[ "$EPISODES" = "2" ]
[ "$CHANNELS" = "2" ]
[ "$EPG" = "3" ]

{
  echo "MEDIA_XUPER_INGEST_V1_FIX_READY"
  echo "vod_test=$VOD"
  echo "live_test=$LIVE"
  echo "video_item_count=$ITEMS"
  echo "episode_count=$EPISODES"
  echo "live_channel_count=$CHANNELS"
  echo "epg_program_count=$EPG"
  echo "foreign_key_check=${FK:-OK}"
  echo "inbox=$INBOX"
  echo "archive=$ARCHIVE"
  echo "ingest=$XUPER/ingest_xuper.py"
} > "$OUT"

chmod 600 "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-xuper-ingest-v1-fix.txt" || true
fi

echo "MEDIA_XUPER_INGEST_V1_FIX_READY"
