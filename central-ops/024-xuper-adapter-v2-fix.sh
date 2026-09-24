#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center/video"
ADAPTER="$BASE/adapters/xuper"
OUT="/var/lib/conector/xuper-adapter-v2-fix.txt"
mkdir -p "$ADAPTER" /var/lib/conector

python3 - <<'PY'
from pathlib import Path
p = Path("/home/ubuntu/Central/media_center/video/adapters/xuper/import_xuper.py")
s = p.read_text(encoding="utf-8")

old = '''def iter_candidates(node):
    if isinstance(node, dict):
        if node.get("contentId") and (node.get("name") or node.get("alias")):
            yield node
        for v in node.values():
            yield from iter_candidates(v)
    elif isinstance(node, list):
        for v in node:
            yield from iter_candidates(v)
'''

new = '''def iter_candidates(node):
    if isinstance(node, dict):
        if node.get("contentId") and (node.get("name") or node.get("alias")):
            yield node
        for k, v in node.items():
            if k in {"simpleProgramList", "episodeList", "sameSeasonSeriesList", "subtitleList"}:
                continue
            yield from iter_candidates(v)
    elif isinstance(node, list):
        for v in node:
            yield from iter_candidates(v)
'''

if old not in s:
    raise SystemExit("ITER_CANDIDATES_PATCH_TARGET_NOT_FOUND")

p.write_text(s.replace(old, new), encoding="utf-8")
PY

TESTDB="/tmp/xuper-adapter-v2-fix-test.db"
rm -f "$TESTDB"
sqlite3 "$TESTDB" < "$BASE/schema.sql"

RUN1="$(python3 "$ADAPTER/import_xuper.py" "$ADAPTER/fixture_v2.json" --db "$TESTDB")"
RUN2="$(python3 "$ADAPTER/import_xuper.py" "$ADAPTER/fixture_v2.json" --db "$TESTDB")"

ITEMS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM video_item;")"
REFS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM external_ref WHERE provider='xuper';")"
SEASONS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM season;")"
EPISODES="$(sqlite3 "$TESTDB" "SELECT count(*) FROM episode;")"
ORPHAN_EP_ITEMS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM video_item WHERE id LIKE 'xuper:fixture-episode-%';")"
FK="$(sqlite3 "$TESTDB" "PRAGMA foreign_key_check;")"

if [ "$ITEMS" != "2" ]; then
  echo "unexpected_video_item_count=$ITEMS" >&2
  exit 1
fi

if [ "$EPISODES" != "2" ]; then
  echo "unexpected_episode_count=$EPISODES" >&2
  exit 1
fi

if [ "$ORPHAN_EP_ITEMS" != "0" ]; then
  echo "nested_episodes_leaked_into_video_item=$ORPHAN_EP_ITEMS" >&2
  exit 1
fi

{
  echo "XUPER_ADAPTER_V2_FIX_READY"
  echo "first_import=$RUN1"
  echo "second_import=$RUN2"
  echo "video_item_count=$ITEMS"
  echo "xuper_ref_count=$REFS"
  echo "season_count=$SEASONS"
  echo "episode_count=$EPISODES"
  echo "nested_episode_video_items=$ORPHAN_EP_ITEMS"
  echo "foreign_key_check=${FK:-OK}"
} > "$OUT"

chmod 600 "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-adapter-v2-fix.txt" || true
fi

echo "XUPER_ADAPTER_V2_FIX_READY"
