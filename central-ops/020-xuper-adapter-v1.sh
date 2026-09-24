#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center/video"
ADAPTER="$BASE/adapters/xuper"
OUT="/var/lib/conector/xuper-adapter-v1.txt"
mkdir -p "$ADAPTER" /var/lib/conector

cat > "$ADAPTER/import_xuper.py" <<'PY'
#!/usr/bin/env python3
import argparse, json, sqlite3, re
from pathlib import Path

def as_bool(v):
    if isinstance(v, bool): return int(v)
    if isinstance(v, (int, float)): return int(bool(v))
    if isinstance(v, str): return int(v.strip().lower() in {"1","true","yes","y","si","sí"})
    return 0

def as_float(v):
    try:
        if v is None or v == "": return None
        return float(v)
    except Exception:
        return None

def duration_seconds(v):
    if v is None: return None
    if isinstance(v, (int, float)):
        n = int(v)
        return n // 1000 if n > 100000 else n
    s = str(v).strip()
    if s.isdigit():
        n = int(s)
        return n // 1000 if n > 100000 else n
    parts = s.split(":")
    if all(p.isdigit() for p in parts):
        nums = list(map(int, parts))
        if len(nums) == 3: return nums[0]*3600 + nums[1]*60 + nums[2]
        if len(nums) == 2: return nums[0]*60 + nums[1]
    return None

def guess_kind(obj):
    blob = " ".join(str(obj.get(k, "")) for k in ("programType","contentType","type","tags","name")).lower()
    if "anime" in blob or "animation" in blob: return "anime"
    if obj.get("simpleProgramList") or obj.get("sameSeasonSeriesList") or obj.get("volumnCount") or obj.get("updateCount"):
        return "series"
    if any(x in blob for x in ("series","serie","tvshow","season")): return "series"
    return "movie"

def iter_candidates(node):
    if isinstance(node, dict):
        if node.get("contentId") and (node.get("name") or node.get("alias")):
            yield node
        for v in node.values():
            yield from iter_candidates(v)
    elif isinstance(node, list):
        for v in node:
            yield from iter_candidates(v)

def normalize(obj):
    cid = str(obj.get("contentId") or "").strip()
    return {
        "external_id": cid,
        "kind": guess_kind(obj),
        "title": str(obj.get("name") or obj.get("alias") or cid).strip(),
        "original_title": obj.get("alias") or None,
        "description": obj.get("description") or obj.get("descriptionCompt") or obj.get("viewPoint") or obj.get("viewpoint") or None,
        "release_date": obj.get("releaseTime") or obj.get("shelveTime") or obj.get("updateTime") or None,
        "country": obj.get("originalCountry") or None,
        "original_language": obj.get("language") or None,
        "duration_seconds": duration_seconds(obj.get("duration")),
        "score": as_float(obj.get("score")),
        "restricted": as_bool(obj.get("restricted")),
        "status": "active",
        "provider_type": obj.get("contentType") or obj.get("type") or None,
        "raw_program_type": obj.get("programType") or None
    }

def upsert(conn, item):
    ref = conn.execute(
        "SELECT video_item_id FROM external_ref WHERE provider=? AND external_id=?",
        ("xuper", item["external_id"])
    ).fetchone()
    values = (
        item["kind"], item["title"], item["original_title"], item["description"],
        item["release_date"], item["country"], item["original_language"],
        item["duration_seconds"], item["score"], item["restricted"], item["status"]
    )
    if ref:
        vid = ref[0]
        conn.execute(
            "UPDATE video_item SET kind=?,title=?,original_title=?,description=?,release_date=?,country=?,original_language=?,duration_seconds=?,score=?,restricted=?,status=?,updated_at=CURRENT_TIMESTAMP WHERE id=?",
            values + (vid,)
        )
        conn.execute(
            "UPDATE external_ref SET provider_type=?,raw_program_type=? WHERE provider=? AND external_id=?",
            (item["provider_type"], item["raw_program_type"], "xuper", item["external_id"])
        )
        return False
    cur = conn.execute(
        "INSERT INTO video_item(kind,title,original_title,description,release_date,country,original_language,duration_seconds,score,restricted,status) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        values
    )
    conn.execute(
        "INSERT INTO external_ref(provider,external_id,video_item_id,provider_type,raw_program_type) VALUES (?,?,?,?,?)",
        ("xuper", item["external_id"], cur.lastrowid, item["provider_type"], item["raw_program_type"])
    )
    return True

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json_file")
    ap.add_argument("--db", default="/home/ubuntu/Central/media_center/video/catalog.db")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    data = json.loads(Path(args.json_file).read_text(encoding="utf-8"))
    items, seen = [], set()
    for obj in iter_candidates(data):
        item = normalize(obj)
        if not item["external_id"] or item["external_id"] in seen:
            continue
        seen.add(item["external_id"])
        items.append(item)

    if args.dry_run:
        print(json.dumps({"provider":"xuper","found":len(items),"items":items[:20]}, ensure_ascii=False))
        return

    conn = sqlite3.connect(args.db)
    conn.execute("PRAGMA foreign_keys=ON")
    inserted = updated = 0
    try:
        for item in items:
            if upsert(conn, item): inserted += 1
            else: updated += 1
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    print(json.dumps({"provider":"xuper","found":len(items),"inserted":inserted,"updated":updated,"db":args.db}, ensure_ascii=False))

if __name__ == "__main__":
    main()
PY
chmod 755 "$ADAPTER/import_xuper.py"

cat > "$ADAPTER/fixture_v1.json" <<'JSON'
{
  "returnCode": "0",
  "data": {
    "assetList": [
      {
        "contentId": "fixture-movie-001",
        "name": "Película de prueba",
        "alias": "Fixture Movie",
        "description": "Fixture local; no proviene del catálogo real.",
        "programType": "movie",
        "contentType": "vod",
        "duration": 7200,
        "score": 8.1,
        "restricted": false
      },
      {
        "contentId": "fixture-series-001",
        "name": "Serie de prueba",
        "programType": "series",
        "contentType": "vod",
        "updateCount": 8
      }
    ]
  }
}
JSON

cat > "$ADAPTER/README.md" <<'MD'
# Adaptador Xuper v1

Convierte respuestas JSON de catálogo Xuper al esquema canónico de Video.

Estado:
- Importa video_item y external_ref.
- Deduplica por provider=xuper + contentId.
- Es idempotente: una segunda importación actualiza.
- fixture_v1.json es solo una fixture local, no datos reales.
- Próximo: imágenes/tags/créditos, temporadas/episodios, Live TV/EPG y resolver.
MD

TESTDB="/tmp/xuper-adapter-test.db"
rm -f "$TESTDB"
sqlite3 "$TESTDB" < "$BASE/schema.sql"
DRY="$(python3 "$ADAPTER/import_xuper.py" "$ADAPTER/fixture_v1.json" --db "$TESTDB" --dry-run)"
RUN1="$(python3 "$ADAPTER/import_xuper.py" "$ADAPTER/fixture_v1.json" --db "$TESTDB")"
RUN2="$(python3 "$ADAPTER/import_xuper.py" "$ADAPTER/fixture_v1.json" --db "$TESTDB")"
COUNT="$(sqlite3 "$TESTDB" "SELECT count(*) FROM video_item;")"
REFS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM external_ref WHERE provider='xuper';")"

{
  echo "XUPER_ADAPTER_V1_READY"
  echo "adapter=$ADAPTER/import_xuper.py"
  echo "fixture=$ADAPTER/fixture_v1.json"
  echo "test_db=$TESTDB"
  echo "dry_run=$DRY"
  echo "first_import=$RUN1"
  echo "second_import=$RUN2"
  echo "video_item_count=$COUNT"
  echo "xuper_ref_count=$REFS"
} > "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-adapter-v1.txt" || true
fi

echo "XUPER_ADAPTER_V1_READY"
