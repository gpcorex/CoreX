#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center"
INBOX="$BASE/inbox/xuper"
TOOLS="$BASE/tools"
OUT="/var/lib/conector/media-xuper-import-tool.txt"

mkdir -p "$INBOX" "$TOOLS" /var/lib/conector

cat > "$TOOLS/import_xuper_payload.py" <<'PY'
#!/usr/bin/env python3
import argparse, json, os, shutil, sys, tempfile, time
from pathlib import Path

INBOX = Path("/home/ubuntu/Central/media_center/inbox/xuper")

def main():
    ap = argparse.ArgumentParser(description="Validate and enqueue one authorized Xuper JSON payload.")
    ap.add_argument("path", help="Path to JSON payload")
    ap.add_argument("--name", default=None, help="Optional inbox filename")
    args = ap.parse_args()

    src = Path(args.path)
    if not src.is_file():
        raise SystemExit(f"missing file: {src}")

    try:
        with src.open("r", encoding="utf-8") as fh:
            obj = json.load(fh)
    except Exception as e:
        raise SystemExit(f"invalid json: {e}")

    # Lightweight sanity check only. Actual VOD/live classification is done by ingest_xuper.py.
    blob = json.dumps(obj, ensure_ascii=False)
    hints = [
        "contentId","assetList","simpleProgramList","episodeList",
        "channelCode","liveAddressList","programList"
    ]
    found = [k for k in hints if k in blob]
    if not found:
        raise SystemExit("json is valid but does not look like a Xuper catalog/live payload")

    INBOX.mkdir(parents=True, exist_ok=True)
    base = args.name or f"xuper-real-{int(time.time())}.json"
    if not base.endswith(".json"):
        base += ".json"
    dst = INBOX / base

    # Atomic handoff so the path watcher never sees a partial file.
    fd, tmpname = tempfile.mkstemp(prefix=".xuper-", suffix=".json", dir=str(INBOX))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(obj, out, ensure_ascii=False)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmpname, dst)
    finally:
        if os.path.exists(tmpname):
            os.unlink(tmpname)

    print(f"ENQUEUED={dst}")
    print("HINTS=" + ",".join(found))

if __name__ == "__main__":
    main()
PY
chmod +x "$TOOLS/import_xuper_payload.py"

cat > "$TOOLS/xuper_payload_template.json" <<'JSON'
{
  "_note": "Replace this file with one authorized, current Xuper JSON response. Do not paste passwords, tokens, cookies, license secrets, or temporary credentials here.",
  "_accepted_examples": [
    "VOD catalog/detail payload containing contentId / assetList / simpleProgramList / episodeList",
    "Live TV payload containing channelCode / liveAddressList / programList"
  ]
}
JSON

{
  echo "MEDIA_XUPER_IMPORT_TOOL_READY"
  echo "timestamp=$(date -Is)"
  echo "tool=$TOOLS/import_xuper_payload.py"
  echo "template=$TOOLS/xuper_payload_template.json"
  echo "inbox=$INBOX"
  echo "watcher=$(systemctl is-active media-xuper-inbox.path 2>/dev/null || true)"
  echo "NOTE=accepts only a user-provided authorized JSON file; secrets/auth material should not be included"
} > "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-xuper-import-tool.txt" || true
fi

cat "$OUT"
