#!/usr/bin/env bash
set -euo pipefail
BASE="/home/ubuntu/Central/media_center"
VIDEO="$BASE/video"
OUT="/var/lib/conector/media-video-schema-v1.txt"
mkdir -p "$VIDEO" /var/lib/conector

cat >"$VIDEO/schema.sql" <<'SQL'
PRAGMA foreign_keys=ON;
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS video_item (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind IN ('movie','series','anime')),
  title TEXT NOT NULL,
  original_title TEXT,
  description TEXT,
  release_date TEXT,
  country TEXT,
  original_language TEXT,
  duration_seconds INTEGER,
  score REAL,
  restricted INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS external_ref (
  provider TEXT NOT NULL,
  external_id TEXT NOT NULL,
  video_item_id TEXT NOT NULL REFERENCES video_item(id) ON DELETE CASCADE,
  provider_type TEXT,
  raw_program_type TEXT,
  PRIMARY KEY(provider, external_id)
);
CREATE INDEX IF NOT EXISTS idx_external_ref_item ON external_ref(video_item_id);

CREATE TABLE IF NOT EXISTS image (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  video_item_id TEXT NOT NULL REFERENCES video_item(id) ON DELETE CASCADE,
  image_type TEXT NOT NULL CHECK(image_type IN ('poster','backdrop','logo','thumbnail','other')),
  url TEXT NOT NULL,
  language TEXT,
  provider TEXT,
  priority INTEGER NOT NULL DEFAULT 0,
  UNIQUE(video_item_id, image_type, url)
);

CREATE TABLE IF NOT EXISTS tag (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS video_item_tag (
  video_item_id TEXT NOT NULL REFERENCES video_item(id) ON DELETE CASCADE,
  tag_id INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
  PRIMARY KEY(video_item_id, tag_id)
);

CREATE TABLE IF NOT EXISTS person (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS credit (
  video_item_id TEXT NOT NULL REFERENCES video_item(id) ON DELETE CASCADE,
  person_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
  role TEXT NOT NULL,
  character_name TEXT,
  position INTEGER,
  PRIMARY KEY(video_item_id, person_id, role, character_name)
);

CREATE TABLE IF NOT EXISTS season (
  id TEXT PRIMARY KEY,
  video_item_id TEXT NOT NULL REFERENCES video_item(id) ON DELETE CASCADE,
  season_number INTEGER NOT NULL,
  title TEXT,
  description TEXT,
  UNIQUE(video_item_id, season_number)
);

CREATE TABLE IF NOT EXISTS episode (
  id TEXT PRIMARY KEY,
  season_id TEXT NOT NULL REFERENCES season(id) ON DELETE CASCADE,
  external_program_id TEXT,
  episode_number INTEGER NOT NULL,
  title TEXT,
  description TEXT,
  duration_seconds INTEGER,
  quality_hint TEXT,
  viewpoint TEXT,
  has_trailer INTEGER NOT NULL DEFAULT 0,
  has_extras INTEGER NOT NULL DEFAULT 0,
  UNIQUE(season_id, episode_number)
);

CREATE TABLE IF NOT EXISTS subtitle_track (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  playable_type TEXT NOT NULL CHECK(playable_type IN ('item','episode')),
  playable_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  language TEXT,
  label TEXT,
  format TEXT,
  source_ref TEXT NOT NULL,
  is_default INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_subtitle_playable ON subtitle_track(playable_type, playable_id);

CREATE TABLE IF NOT EXISTS playback_source (
  id TEXT PRIMARY KEY,
  playable_type TEXT NOT NULL CHECK(playable_type IN ('item','episode')),
  playable_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  provider_media_code TEXT,
  quality TEXT,
  language TEXT,
  format TEXT,
  priority INTEGER NOT NULL DEFAULT 0,
  weight INTEGER NOT NULL DEFAULT 0,
  resolver_key TEXT NOT NULL,
  resolver_ref TEXT,
  drm_hint TEXT,
  active INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_playback_playable ON playback_source(playable_type, playable_id, active);

CREATE TABLE IF NOT EXISTS live_channel (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  external_code TEXT NOT NULL,
  channel_number INTEGER,
  name TEXT NOT NULL,
  alias TEXT,
  quality TEXT,
  restricted INTEGER NOT NULL DEFAULT 0,
  poster_url TEXT,
  favorite INTEGER NOT NULL DEFAULT 0,
  UNIQUE(provider, external_code)
);

CREATE TABLE IF NOT EXISTS live_source (
  id TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL REFERENCES live_channel(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  quality TEXT,
  format TEXT,
  priority INTEGER NOT NULL DEFAULT 0,
  resolver_key TEXT NOT NULL,
  resolver_ref TEXT,
  active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS epg_program (
  id TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL REFERENCES live_channel(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  starts_at TEXT NOT NULL,
  ends_at TEXT NOT NULL,
  external_program_id TEXT
);
CREATE INDEX IF NOT EXISTS idx_epg_channel_time ON epg_program(channel_id, starts_at, ends_at);

CREATE TABLE IF NOT EXISTS user_progress (
  profile_id TEXT NOT NULL,
  playable_type TEXT NOT NULL CHECK(playable_type IN ('item','episode')),
  playable_id TEXT NOT NULL,
  position_seconds INTEGER NOT NULL DEFAULT 0,
  duration_seconds INTEGER,
  completed INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY(profile_id, playable_type, playable_id)
);

CREATE TABLE IF NOT EXISTS user_favorite (
  profile_id TEXT NOT NULL,
  target_type TEXT NOT NULL CHECK(target_type IN ('item','channel')),
  target_id TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY(profile_id, target_type, target_id)
);
SQL

cat >"$VIDEO/xuper_mapping_v1.md" <<'MD'
# Xuper -> Video canonical mapping v1

- `contentId` -> `external_ref.external_id` and canonical dedup input.
- `name` -> `video_item.title`.
- `alias` -> title alias candidate.
- `description` / `descriptionCompt` -> `video_item.description`.
- `contentType`, `programType`, `type` -> adapter classification into `video_item.kind` plus raw values in `external_ref`.
- `releaseTime` -> `video_item.release_date`.
- `originalCountry` -> `video_item.country`.
- `language` -> `video_item.original_language`.
- `duration` -> normalized seconds.
- `score` -> `video_item.score`.
- `restricted` -> `video_item.restricted`.
- `posterList` -> `image`.
- `actorDisplay`, `director` -> normalized `person` + `credit` when parseable; raw source remains adapter evidence.
- `tags`, `keyWords`, `contentTag` -> `tag` / `video_item_tag`.
- `sameSeasonSeriesList(contentId, seasonNumber)` -> `season` relationships.
- `simpleProgramList` and `episodeList` -> `episode`.
- `programContentId` -> `episode.external_program_id`.
- `subtitleList` -> `subtitle_track`.
- `MovieList` and `TotalMovieListItem` quality/audio/video metadata -> source-selection hints, not canonical identity.
- `ProgramInfo.sources` and `Sources` -> `playback_source` resolver metadata.
- `main_addr`, `spared_addr`, `auth`, `license` are resolver inputs and are not copied into the canonical catalog DB as durable public URLs/secrets.
- `Channel` -> `live_channel`.
- `liveAddressList` -> `live_source` through resolver refs.
- `EpgData.programList` -> `epg_program`.

## Design rule
Metadata identifies **what the content is**. Playback resolvers determine **how it is played**. Provider-specific auth, license and temporary URLs stay outside the canonical catalog.
MD

cat >"$BASE/ARCHITECTURE.md" <<'MD'
# Centro Multimedia

Extensible media platform with independent engines.

- `video/`: movies, series, anime, live TV.
- `audio/`: reserved for music, radio and podcasts; separate catalog/data model.
- shared infrastructure may later contain profiles, global search, recommendations, cache and cross-media favorites.

Current implementation starts with the Video canonical catalog. Provider adapters normalize source-specific data into this schema. Playback remains resolver-based and separate from metadata.
MD

DB="$VIDEO/catalog.db"
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$DB" < "$VIDEO/schema.sql"
  sqlite3 "$DB" "PRAGMA foreign_keys; SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" >"$OUT"
else
  { echo "sqlite3=missing"; echo "schema_written=$VIDEO/schema.sql"; } >"$OUT"
fi

echo "schema=$VIDEO/schema.sql" >>"$OUT"
echo "mapping=$VIDEO/xuper_mapping_v1.md" >>"$OUT"
echo "architecture=$BASE/ARCHITECTURE.md" >>"$OUT"
echo "db=$DB" >>"$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-video-schema-v1.txt" || true
fi
echo "MEDIA_VIDEO_SCHEMA_V1_READY"
