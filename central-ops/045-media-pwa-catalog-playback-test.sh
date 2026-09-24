#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center"
DB="$BASE/video/catalog.db"
OUT="/var/lib/conector/media-pwa-catalog-playback-test.txt"
ITEM_ID="test:pwa-direct-001"
SOURCE_ID="test:pwa-direct-source-001"
URL="https://samplefile.com/samples/download/video/mp4/mp4_15s_sample_file_868KB.mp4/"

mkdir -p /var/lib/conector
: > "$OUT"

python3 - "$DB" "$ITEM_ID" "$SOURCE_ID" "$URL" <<'PY'
import sqlite3, sys, datetime

db_path,item_id,source_id,url=sys.argv[1:]
conn=sqlite3.connect(db_path)
conn.row_factory=sqlite3.Row
conn.execute("PRAGMA foreign_keys=ON")

def table_info(name):
    return [dict(r) for r in conn.execute(f"PRAGMA table_info({name})")]

def ensure_video_item():
    exists=conn.execute("SELECT 1 FROM video_item WHERE id=?", (item_id,)).fetchone()
    if exists:
        conn.execute("UPDATE video_item SET title=? WHERE id=?", ("Prueba técnica PWA", item_id))
        return "updated"
    cols=table_info("video_item")
    names={c["name"] for c in cols}
    now=datetime.datetime.now(datetime.timezone.utc).isoformat()
    known={
        "id": item_id,
        "kind": "movie",
        "title": "Prueba técnica PWA",
        "original_title": "Prueba técnica PWA",
        "description": "Item técnico para validar catálogo → fuente → resolver → reproducción en la PWA.",
        "release_year": 2026,
        "year": 2026,
        "created_at": now,
        "updated_at": now,
        "restricted": 0,
        "duration_seconds": 15,
        "score": 0,
    }
    data={}
    for c in cols:
        n=c["name"]
        if n in known:
            data[n]=known[n]
        elif c["notnull"] and c["dflt_value"] is None and not c["pk"]:
            t=(c["type"] or "").upper()
            if "INT" in t:
                data[n]=0
            elif any(x in t for x in ("REAL","FLOA","DOUB","NUM")):
                data[n]=0.0
            else:
                data[n]=""
    keys=list(data)
    sql="INSERT INTO video_item ("+",".join(keys)+") VALUES ("+",".join(["?"]*len(keys))+")"
    conn.execute(sql,[data[k] for k in keys])
    return "inserted"

state=ensure_video_item()
conn.execute("DELETE FROM playback_source WHERE id=?", (source_id,))
conn.execute("""
INSERT INTO playback_source
(id, playable_type, playable_id, provider, quality, language, format,
 priority, weight, resolver_key, resolver_ref, drm_hint, active)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
""",(
    source_id,"item",item_id,"test","SD","und","mp4",
    100,100,"direct_url",url,None,1
))
conn.commit()
fk=list(conn.execute("PRAGMA foreign_key_check"))
print("video_item_state="+state)
print("foreign_key_check="+("OK" if not fk else repr(fk)))
print("video_item_count="+str(conn.execute("SELECT count(*) FROM video_item").fetchone()[0]))
print("playback_source_count="+str(conn.execute("SELECT count(*) FROM playback_source").fetchone()[0]))
conn.close()
PY

sudo systemctl restart media-catalog.service
sleep 1

{
  echo "MEDIA_PWA_CATALOG_PLAYBACK_TEST_READY"
  echo "timestamp=$(date -Is)"
  echo "item_id=$ITEM_ID"
  echo "source_id=$SOURCE_ID"
  echo "api_health=$(curl -fsS http://127.0.0.1:8092/health || true)"
  echo "item=$(curl -fsS "http://127.0.0.1:8092/video/item/$ITEM_ID" || true)"
  echo "playback=$(curl -fsS "http://127.0.0.1:8092/video/playback?type=item&id=$ITEM_ID" || true)"
  echo "player=https://cen-tral.duckdns.org/multimedia/player-test.html"
  echo "NOTE=test item/source only; provider=test, not Xuper"
} >> "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-pwa-catalog-playback-test.txt" || true
fi

cat "$OUT"
