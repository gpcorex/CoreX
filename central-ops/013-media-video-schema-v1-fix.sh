#!/usr/bin/env bash
set -euo pipefail
VIDEO="/home/ubuntu/Central/media_center/video"
DB="$VIDEO/catalog.db"
OUT="/var/lib/conector/media-video-schema-v1-fix.txt"
mkdir -p /var/lib/conector

if ! command -v sqlite3 >/dev/null 2>&1; then
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y sqlite3 >/dev/null
fi

sqlite3 "$DB" < "$VIDEO/schema.sql"
{
  echo "sqlite3=$(sqlite3 --version | awk '{print $1}')"
  echo "db=$DB"
  echo "foreign_keys=$(sqlite3 "$DB" "PRAGMA foreign_keys;")"
  echo "[tables]"
  sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
} > "$OUT"
chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-video-schema-v1-fix.txt" || true
fi
echo "MEDIA_VIDEO_SCHEMA_V1_FIX_READY"
