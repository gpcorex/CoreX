#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center/video"
ADAPTER="$BASE/adapters/xuper"
OUT="/var/lib/conector/xuper-adapter-v1-fix.txt"
mkdir -p "$ADAPTER" /var/lib/conector

python3 - <<'PY'
from pathlib import Path
p = Path("/home/ubuntu/Central/media_center/video/adapters/xuper/import_xuper.py")
s = p.read_text(encoding="utf-8")

old = '''    cur = conn.execute(
        "INSERT INTO video_item(kind,title,original_title,description,release_date,country,original_language,duration_seconds,score,restricted,status) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        values
    )
    conn.execute(
        "INSERT INTO external_ref(provider,external_id,video_item_id,provider_type,raw_program_type) VALUES (?,?,?,?,?)",
        ("xuper", item["external_id"], cur.lastrowid, item["provider_type"], item["raw_program_type"])
    )
    return True
'''

new = '''    canonical_id = "xuper:" + item["external_id"]
    conn.execute(
        "INSERT INTO video_item(id,kind,title,original_title,description,release_date,country,original_language,duration_seconds,score,restricted,status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (canonical_id,) + values
    )
    conn.execute(
        "INSERT INTO external_ref(provider,external_id,video_item_id,provider_type,raw_program_type) VALUES (?,?,?,?,?)",
        ("xuper", item["external_id"], canonical_id, item["provider_type"], item["raw_program_type"])
    )
    return True
'''

if old not in s:
    raise SystemExit("PATCH_TARGET_NOT_FOUND")
p.write_text(s.replace(old, new), encoding="utf-8")
PY

TESTDB="/tmp/xuper-adapter-test.db"
rm -f "$TESTDB"
sqlite3 "$TESTDB" < "$BASE/schema.sql"

RUN1="$(python3 "$ADAPTER/import_xuper.py" "$ADAPTER/fixture_v1.json" --db "$TESTDB")"
RUN2="$(python3 "$ADAPTER/import_xuper.py" "$ADAPTER/fixture_v1.json" --db "$TESTDB")"
COUNT="$(sqlite3 "$TESTDB" "SELECT count(*) FROM video_item;")"
REFS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM external_ref WHERE provider='xuper';")"
IDS="$(sqlite3 "$TESTDB" "SELECT id||'|'||title FROM video_item ORDER BY id;")"
FK="$(sqlite3 "$TESTDB" "PRAGMA foreign_key_check;")"

{
  echo "XUPER_ADAPTER_V1_FIX_READY"
  echo "first_import=$RUN1"
  echo "second_import=$RUN2"
  echo "video_item_count=$COUNT"
  echo "xuper_ref_count=$REFS"
  echo "foreign_key_check=${FK:-OK}"
  echo "ids:"
  echo "$IDS"
} > "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-adapter-v1-fix.txt" || true
fi

echo "XUPER_ADAPTER_V1_FIX_READY"
