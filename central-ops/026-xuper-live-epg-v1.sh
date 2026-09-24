#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center/video"
ADAPTER="$BASE/adapters/xuper"
OUT="/var/lib/conector/xuper-live-epg-v1.txt"
mkdir -p "$ADAPTER" /var/lib/conector

cat > "$ADAPTER/import_xuper_live.py" <<'PY'
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

def iter_dicts(node):
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from iter_dicts(v)
    elif isinstance(node, list):
        for v in node:
            yield from iter_dicts(v)

def channel_candidates(data):
    seen = set()
    for obj in iter_dicts(data):
        code = obj.get("channelCode")
        name = obj.get("name") or obj.get("channelName")
        if not code or not name:
            continue
        key = str(code)
        if key in seen:
            continue
        seen.add(key)
        yield obj

def poster_url(obj):
    for k in ("posterUrl","showPosterUrl","showIconUrl"):
        if obj.get(k):
            return str(obj[k])
    pl = obj.get("posterList")
    if isinstance(pl, list) and pl:
        first = pl[0]
        if isinstance(first, str): return first
        if isinstance(first, dict):
            for k in ("url","posterUrl","imageUrl","imgUrl"):
                if first.get(k): return str(first[k])
    return None

def upsert_channel(conn, obj):
    code = str(obj.get("channelCode")).strip()
    cid = "xuper-live:" + code
    conn.execute(
        """INSERT INTO live_channel(id,provider,external_code,channel_number,name,alias,quality,restricted,poster_url,favorite)
           VALUES (?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(provider,external_code) DO UPDATE SET
             channel_number=excluded.channel_number,
             name=excluded.name,
             alias=excluded.alias,
             quality=excluded.quality,
             restricted=excluded.restricted,
             poster_url=excluded.poster_url""",
        (
            cid, "xuper", code, as_int(obj.get("channelNumber") or obj.get("fixedChannelNumber")),
            obj.get("name") or obj.get("channelName") or code,
            obj.get("alias") or None,
            obj.get("quality") or None,
            as_bool(obj.get("restricted")),
            poster_url(obj),
            as_bool(obj.get("isFav"))
        )
    )
    row = conn.execute(
        "SELECT id FROM live_channel WHERE provider=? AND external_code=?",
        ("xuper", code)
    ).fetchone()
    return row[0]

def import_live_sources(conn, channel_id, obj):
    items = obj.get("liveAddressList")
    if not isinstance(items, list):
        return 0
    count = 0
    for idx, src in enumerate(items):
        if not isinstance(src, dict):
            continue
        resolver_ref = str(src.get("playCode") or src.get("id") or src.get("code") or idx)
        sid = stable_id("xuper-live-source", channel_id, resolver_ref, src.get("quality"), src.get("format"))
        conn.execute(
            """INSERT INTO live_source(id,channel_id,provider,quality,format,priority,resolver_key,resolver_ref,active)
               VALUES (?,?,?,?,?,?,?,?,1)
               ON CONFLICT(id) DO UPDATE SET
                 quality=excluded.quality,
                 format=excluded.format,
                 priority=excluded.priority,
                 resolver_ref=excluded.resolver_ref,
                 active=1""",
            (
                sid, channel_id, "xuper",
                src.get("quality") or None,
                src.get("format") or src.get("videoFormat") or None,
                int(src.get("priority") or max(0, 100-idx)),
                "xuper-live",
                resolver_ref
            )
        )
        count += 1
    return count

def normalize_time(v):
    if v is None:
        return None
    return str(v)

def import_epg(conn, channel_id, obj):
    plist = obj.get("programList")
    if not isinstance(plist, list):
        return 0
    count = 0
    for idx, p in enumerate(plist):
        if not isinstance(p, dict):
            continue
        title = p.get("programName") or p.get("name") or p.get("title")
        starts = normalize_time(p.get("startTime") or p.get("start") or p.get("beginTime"))
        ends = normalize_time(p.get("endTime") or p.get("end") or p.get("stopTime"))
        if not title or not starts or not ends:
            continue
        ext = p.get("contentId") or p.get("programId") or p.get("id")
        eid = stable_id("xuper-epg", channel_id, ext, starts, ends, idx)
        conn.execute(
            """INSERT INTO epg_program(id,channel_id,title,description,starts_at,ends_at,external_program_id)
               VALUES (?,?,?,?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET
                 title=excluded.title,
                 description=excluded.description,
                 starts_at=excluded.starts_at,
                 ends_at=excluded.ends_at,
                 external_program_id=excluded.external_program_id""",
            (
                eid, channel_id, title,
                p.get("description") or p.get("desc") or None,
                starts, ends,
                str(ext) if ext is not None else None
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
    channels = list(channel_candidates(data))

    if args.dry_run:
        print(json.dumps({
            "provider":"xuper",
            "channels":len(channels),
            "codes":[str(x.get("channelCode")) for x in channels[:20]]
        }, ensure_ascii=False))
        return

    conn = sqlite3.connect(args.db)
    conn.execute("PRAGMA foreign_keys=ON")
    ch_count = src_count = epg_count = 0

    try:
        for obj in channels:
            cid = upsert_channel(conn, obj)
            ch_count += 1
            src_count += import_live_sources(conn, cid, obj)
            epg_count += import_epg(conn, cid, obj)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    print(json.dumps({
        "provider":"xuper",
        "channels":ch_count,
        "live_sources":src_count,
        "epg_programs":epg_count,
        "db":args.db
    }, ensure_ascii=False))

if __name__ == "__main__":
    main()
PY

chmod 755 "$ADAPTER/import_xuper_live.py"

cat > "$ADAPTER/fixture_live_v1.json" <<'JSON'
{
  "returnCode": "0",
  "data": {
    "channelList": [
      {
        "channelCode": "ch-001",
        "channelNumber": 7,
        "name": "Canal de prueba",
        "alias": "Prueba HD",
        "quality": "HD",
        "restricted": false,
        "posterUrl": "https://example.invalid/channel-001.png",
        "liveAddressList": [
          {"playCode":"main","quality":"HD","format":"hls","priority":100},
          {"playCode":"backup","quality":"SD","format":"hls","priority":50}
        ],
        "programList": [
          {
            "contentId":"epg-001",
            "programName":"Noticias",
            "startTime":"2026-09-24T10:00:00-03:00",
            "endTime":"2026-09-24T11:00:00-03:00"
          },
          {
            "contentId":"epg-002",
            "programName":"Película",
            "startTime":"2026-09-24T11:00:00-03:00",
            "endTime":"2026-09-24T13:00:00-03:00"
          }
        ]
      },
      {
        "channelCode": "ch-002",
        "channelNumber": 9,
        "name": "Canal Dos",
        "quality": "FHD",
        "liveAddressList": [
          {"playCode":"main","quality":"FHD","format":"hls","priority":100}
        ],
        "programList": [
          {
            "contentId":"epg-003",
            "programName":"Serie",
            "startTime":"2026-09-24T10:30:00-03:00",
            "endTime":"2026-09-24T11:30:00-03:00"
          }
        ]
      }
    ]
  }
}
JSON

TESTDB="/tmp/xuper-live-epg-v1-test.db"
rm -f "$TESTDB"
sqlite3 "$TESTDB" < "$BASE/schema.sql"

RUN1="$(python3 "$ADAPTER/import_xuper_live.py" "$ADAPTER/fixture_live_v1.json" --db "$TESTDB")"
RUN2="$(python3 "$ADAPTER/import_xuper_live.py" "$ADAPTER/fixture_live_v1.json" --db "$TESTDB")"

CHANNELS="$(sqlite3 "$TESTDB" "SELECT count(*) FROM live_channel;")"
SOURCES="$(sqlite3 "$TESTDB" "SELECT count(*) FROM live_source;")"
EPG="$(sqlite3 "$TESTDB" "SELECT count(*) FROM epg_program;")"
FK="$(sqlite3 "$TESTDB" "PRAGMA foreign_key_check;")"
ROWS="$(sqlite3 "$TESTDB" "SELECT c.external_code||'|'||c.name||'|'||count(e.id) FROM live_channel c LEFT JOIN epg_program e ON e.channel_id=c.id GROUP BY c.id ORDER BY c.external_code;")"

[ "$CHANNELS" = "2" ]
[ "$SOURCES" = "3" ]
[ "$EPG" = "3" ]

{
  echo "XUPER_LIVE_EPG_V1_READY"
  echo "first_import=$RUN1"
  echo "second_import=$RUN2"
  echo "live_channel_count=$CHANNELS"
  echo "live_source_count=$SOURCES"
  echo "epg_program_count=$EPG"
  echo "foreign_key_check=${FK:-OK}"
  echo "channels:"
  echo "$ROWS"
} > "$OUT"

chmod 600 "$OUT"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/xuper-live-epg-v1.txt" || true
fi

echo "XUPER_LIVE_EPG_V1_READY"
