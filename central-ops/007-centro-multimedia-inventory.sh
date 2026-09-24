#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/media-inventory.txt"
PUB="/srv/apps/conector/www/results/media-inventory.txt"
mkdir -p /var/lib/conector /srv/apps/conector/www/results

{
  echo "CENTRO_MULTIMEDIA_INVENTORY_V1"
  echo "generated_at=$(date -Is)"
  echo "host=$(hostname)"
  echo "repo_head=$(git -C /opt/corex/repo rev-parse HEAD 2>/dev/null || true)"
  echo

  echo "[KNOWN_ROOTS]"
  for p in /home/ubuntu/Central /home/ubuntu/Interfaz /srv/apps /opt/corex/repo /home/ubuntu; do
    if [ -e "$p" ]; then
      du -sh "$p" 2>/dev/null || true
    else
      echo "$p=MISSING"
    fi
  done
  echo

  echo "[MEDIA_RELATED_PATHS]"
  find /home/ubuntu/Central /home/ubuntu/Interfaz /srv/apps /opt/corex/repo /home/ubuntu \
    -xdev \( -type f -o -type d \) \
    \( -iname '*xuper*' -o -iname '*crunch*' -o -iname '*auditor*' -o -iname '*media*' \
       -o -iname '*catalog*' -o -iname '*vod*' -o -iname '*iptv*' -o -iname '*m3u*' \
       -o -iname '*stream*' -o -iname '*player*' -o -iname '*reproductor*' \) \
    -printf '%y %p\n' 2>/dev/null | sort -u | head -n 1200
  echo

  echo "[DATA_FILES]"
  find /home/ubuntu/Central /srv/apps /home/ubuntu \
    -xdev -type f \
    \( -iname '*.db' -o -iname '*.sqlite' -o -iname '*.sqlite3' -o -iname '*.json' \
       -o -iname '*.jsonl' -o -iname '*.ndjson' -o -iname '*.m3u' -o -iname '*.m3u8' \
       -o -iname '*.csv' \) \
    -printf '%s %p\n' 2>/dev/null | sort -nr | head -n 500
  echo

  echo "[CENTRAL_MEDIA_KEYWORDS]"
  grep -RIlE 'xuper|crunchyroll|catalog|stream|reproductor|player|iptv|m3u|vod' \
    /home/ubuntu/Central /home/ubuntu/Interfaz 2>/dev/null | sort -u | head -n 500
  echo

  echo "[SERVICES_RELEVANT]"
  systemctl list-unit-files --type=service --no-pager 2>/dev/null \
    | grep -Ei 'central|interfaz|auditor|xuper|crunch|media|conector' || true
  echo

  echo "[LISTENING_PORTS]"
  ss -ltnp 2>/dev/null | head -n 120 || true
} >"$OUT"

cp "$OUT" "$PUB"
chmod 600 "$OUT"
chmod 644 "$PUB"

if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-inventory.txt" || true
fi

echo "CENTRO_MULTIMEDIA_INVENTORY_READY"
