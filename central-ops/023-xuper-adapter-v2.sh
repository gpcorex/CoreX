#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center/video"
ADAPTER="$BASE/adapters/xuper"
OUT="/var/lib/conector/xuper-adapter-v2.txt"
mkdir -p "$ADAPTER" /var/lib/conector

cat > "$ADAPTER/import_xuper.py" <<'PY'
#!/usr/bin/env python3
import argparse, hashlib, json, sqlite3
from pathlib import Path

def stable_id(prefix, *parts):
    raw = "|".join("" if p is None else str(p) for p in parts)
    return prefix + ":" + hashlib.sha1(raw.encode("utf-8")).hexdigest()[:20]

def as_bool(v):
    if isinstance(v, bool): return int(v)
    if isinstance(v, (int, float)): return int(bool(v))
    if isinstance(v, str): return int(v.strip().lower() in {"1","true","yes","y","si","sí"})
    return 0

def as_int(v):
    try:
        if v is None or v == "": return None
        return int(float(v))
    except Exception:
        return None

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

def upsert_item(conn, item):
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
        return vid, False

    vid = "xuper:" + item["external_id"]
    conn.execute(
        "INSERT INTO video_item(id,kind,title,original_title,description,release_date,country,original_language,duration_seconds,score,restricted,status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (vid,) + values
    )
    conn.execute(
        "INSERT INTO external_ref(provider,external_id,video_item_id,provider_type,raw_program_type) VALUES (?,?,?,?,?)",
        ("xuper", item["external_id"], vid, item["provider_type"], item["raw_program_type"])
    )
    return vid, True

def image_url(x):
    if isinstance(x, str): return x.strip() or None
    if isinstance(x, dict):
        for k in ("url","posterUrl","imageUrl","imgUrl","address"):
            if x.get(k): return str(x[k]).strip()
    return None

def import_images(conn, vid, obj):
    rows = []
    sources = []
    if isinstance(obj.get("posterList"), list): sources += obj["posterList"]
    for k in ("posterUrl","mIconPosterUrl"):
        if obj.get(k): sources.append(obj[k])
    seen = set()
    for i, x in enumerate(sources):
        url = image_url(x)
        if not url or url in seen: continue
        seen.add(url)
        typ = "poster"
        if isinstance(x, dict):
            raw = str(x.get("type") or x.get("posterType") or "").lower()
            if "back" in raw or "landscape" in raw: typ = "backdrop"
            elif "logo" in raw: typ = "logo"
            elif "thumb" in raw: typ = "thumbnail"
        conn.execute(
            "INSERT OR IGNORE INTO image(video_item_id,image_type,url,provider,priority) VALUES (?,?,?,?,?)",
            (vid, typ, url, "xuper", max(0, 100-i))
        )
        rows.append(url)
    return len(rows)

def tag_values(obj):
    vals = []
    for key in ("tags","keyWords","contentTag"):
        v = obj.get(key)
        if isinstance(v, list):
            vals.extend(str(x).strip() for x in v if str(x).strip())
        elif isinstance(v, str):
            for sep in ("|", ",", ";", "/"):
                if sep in v:
                    vals.extend(x.strip() for x in v.split(sep) if x.strip())
                    break
            else:
                if v.strip(): vals.append(v.strip())
    return list(dict.fromkeys(vals))

def import_tags(conn, vid, obj):
    n = 0
    for name in tag_values(obj):
        conn.execute("INSERT OR IGNORE INTO tag(name) VALUES (?)", (name,))
        tid = conn.execute("SELECT id FROM tag WHERE name=?", (name,)).fetchone()[0]
        cur = conn.execute("INSERT OR IGNORE INTO video_item_tag(video_item_id,tag_id) VALUES (?,?)", (vid, tid))
        if cur.rowcount: n += 1
    return n

def ensure_season(conn, vid, season_number, title=None):
    season_number = season_number or 1
    sid = stable_id("xuper-season", vid, season_number)
    conn.execute(
        "INSERT OR IGNORE INTO season(id,video_item_id,season_number,title) VALUES (?,?,?,?)",
        (sid, vid, season_number, title)
    )
    return sid

def episode_number(ep, fallback):
    for k in ("episodeNumber","seriesNumber","number","episode"):
        n = as_int(ep.get(k))
        if n is not None: return n
    return fallback

def import_episodes(conn, vid, obj):
    eps = []
    if isinstance(obj.get("simpleProgramList"), list): eps += obj["simpleProgramList"]
    if isinstance(obj.get("episodeList"), list): eps += obj["episodeList"]
    seen = set()
    count = 0
    for idx, ep in enumerate(eps, start=1):
        if not isinstance(ep, dict): continue
        ext = str(ep.get("programContentId") or ep.get("contentId") or "").strip()
        num = episode_number(ep, idx)
        season_num = as_int(ep.get("seasonNumber")) or 1
        key = (season_num, num, ext)
        if key in seen: continue
        seen.add(key)
        sid = ensure_season(conn, vid, season_num)
        eid = stable_id("xuper-episode", vid, season_num, num, ext)
        conn.execute(
            """INSERT INTO episode(id,season_id,external_program_id,episode_number,title,description,duration_seconds,quality_hint,viewpoint,has_trailer,has_extras)
               VALUES (?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET
                 external_program_id=excluded.external_program_id,
                 title=excluded.title,
                 description=excluded.description,
                 duration_seconds=excluded.duration_seconds,
                 quality_hint=excluded.quality_hint,
                 viewpoint=excluded.viewpoint,
                 has_trailer=excluded.has_trailer,
                 has_extras=excluded.has_extras""",
            (
                eid, sid, ext or None, num,
                ep.get("name") or ep.get("title") or ("Episodio " + str(num)),
                ep.get("description") or None,
                duration_seconds(ep.get("duration")),
                ep.get("quality") or None,
                ep.get("viewPoint") or ep.get("viewpoint") or None,
                as_bool(ep.get("hasTrailer")),
                as_bool(ep.get("hasTidbits") or ep.get("hasPositive"))
            )
        )
        count += 1
    return count

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json_file")
    ap.add_argument("--db", default="/home/ubuntu/Central/media_center/video/catalog.db")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    data = json.loads(Path(args.json_file).read_text(encoding="utf-8"))
    pairs, seen = [], set()
    for obj in iter_candidates(data):
        item = normalize(obj)
        if not item["external_id"] or item["external_id"] in seen: continue
        seen.add(item["external_id"])
        pairs.append((obj, item))

    if args.dry_run:
        print(json.dumps({"provider":"xuper","found":len(pairs),"items":[x[1] for x in pairs[:20]]}, ensure_ascii=False))
        return

    conn = sqlite3.connect(args.db)
    conn.execute("PRAGMA foreign_keys=ON")
    inserted = updated = images = tags = episodes = 0
    try:
        for obj, item in pairs:
            vid, is_new = upsert_item(conn, item)
            inserted += int(is_new)
            updated += int(not is_new)
            images += import_images(conn, vid, obj)
            tags += import_tags(conn, vid, obj)
            episodes += import_episodes(conn, vid, obj)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    print(json.dumps({
        "provider":"xuper","found":len(pairs),"inserted":inserted,"updated":updated,
        "images":images,"tags":tags,"episodes":episodes,"db":args.db
    }, ensure_ascii=False))

if __name__ == "__main__":
    main()
PY
chmod 755 "$ADAPTER/import_xuper.py"

cat > "$ADAPTER/fixture_v2.json" <<'JSON'
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
        "restricted": false,
        "posterList": [
          {"url":"https://example.invalid/poster-movie.jpg","type":"poster"}
        ],
        "tags": ["Suspenso","Drama"]
      },
      {
        "contentId": "fixture-series-001",
        "name": "Serie de prueba",
        "programType": "series",
        "contentType": "vod",
        "updateCount": 2,
        "posterList": [
          {"url":"https://example.invalid/poster-series.jpg","type":"poster"},
          {"url":"https://example.invalid/backdrop-series.jpg","type":"backdrop"}
        ],
        "tags": "Misterio|Serie",
        "simpleProgramList": [
          {
            "contentId":"fixture-episode-001",
            "name":"Episodio 1",
            "seriesNumber":1,
            "duration":2700,
            "quality":"HD"
          },
          {
            "contentId":"fixture-episode-002",
            "name":"Episodio 2",
            "seriesNumber":2,
            "duration":2800,
            "quality":"FHD"
          }
        ]
      }
    ]
  }
}
JSON

TESTDB="/tmp/xuper-adapter-v2-test.db"
rm -f "$TESTDB"
sqlite3 "$TESTDB" < "$BASE/schema.sql"

RUN1="$(python3 "$ADAPTER/import_xuper.py" "$ADAPTER/fixture_v2.json" --db "$TESTDB")"
RUN2="$(python3 "$ADAPTER/import_xuper.py" "$ADAPTER/fixture_v2.json" --db "$TESTDB")"
ITEMS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM video_item;")"
IMAGES="$(sqlite3 "$TESTDB" "SELECT count(*) FROM image;")"
TAGS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM tag;")"
LINKS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM video_item_tag;")"
SEASONS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM season;")"
EPISODES="$(sqlite3 "$TESTDB" "SELECT count(*) FROM episode;")"
FK="$(sqlite3 "$TESTDB" "PRAGMA foreign_key_check;")"
SERIES_ROWS="$(sqlite3 "$TESTDB" "SELECT s.season_number||'|'||e.episode_number||'|'||e.title FROM season s JOIN episode e ON e.season_id=s.id ORDER BY e.episode_number;")"

{
  echo "XUPER_ADAPTER_V2_READY"
  echo "first_import=$RUN1"
  echo "second_import=$RUN2"
  echo "video_item_count=$ITEMS"
  echo "image_count=$IMAGES"
  echo "tag_count=$TAGS"
  echo "video_item_tag_count=$LINKS"
  echo "season_count=$SEASONS"
  echo "episode_count=$EPISODES"
  echo "foreign_key_check=${FK:-OK}"
  echo "episodes:"
  echo "$SERIES_ROWS"
} > "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-adapter-v2.txt" || true
fi

echo "XUPER_ADAPTER_V2_READY"
