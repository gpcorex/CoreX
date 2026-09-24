#!/usr/bin/env bash
set -euo pipefail

OUT="/var/lib/conector/media-amigonly-dash-probe.txt"
mkdir -p /var/lib/conector
: > "$OUT"

URLS=(
  "https://chromecast.cvattv.com.ar/live/c6eds/Viajar/SA_Live_dash_cenc/Viajar.mpd"
  "https://cdn-py.cvattv.com.ar/live/c6eds/EWTN/SA_Live_dash_enc/EWTN.mpd"
  "https://cdn-py.cvattv.com.ar/live/c4eds/UNICANAL_C4/SA_Live_dash_enc/UNICANAL_C4.mpd"
  "https://cdn-py.cvattv.com.ar/live/c4eds/TELEFUTURO_C4/SA_Live_dash_enc/TELEFUTURO_C4.mpd"
)

echo "MEDIA_AMIGONLY_DASH_PROBE" >> "$OUT"
echo "timestamp=$(date -Is)" >> "$OUT"

for U in "${URLS[@]}"; do
  echo >> "$OUT"
  echo "URL=$U" >> "$OUT"
  H="$(mktemp)"
  B="$(mktemp)"
  CODE="$(curl -L --max-time 12 -sS -D "$H" -o "$B" -w '%{http_code}' "$U" || true)"
  echo "http=$CODE" >> "$OUT"
  echo "content_type=$(awk 'BEGIN{IGNORECASE=1}/^content-type:/{gsub("\r",""); print substr($0,index($0,":")+2)}' "$H" | tail -1)" >> "$OUT"
  echo "bytes=$(wc -c < "$B" 2>/dev/null || echo 0)" >> "$OUT"
  if [ "$CODE" = "200" ] && grep -aq '<MPD' "$B"; then
    echo "mpd=yes" >> "$OUT"
    echo "content_protection_count=$(grep -aoi '<ContentProtection' "$B" | wc -l)" >> "$OUT"
    echo "widevine_refs=$(grep -aio 'widevine\|edef8ba9' "$B" | wc -l)" >> "$OUT"
    echo "playready_refs=$(grep -aio 'playready\|9a04f079' "$B" | wc -l)" >> "$OUT"
    echo "adaptation_sets=$(grep -aoi '<AdaptationSet' "$B" | wc -l)" >> "$OUT"
    echo "representations=$(grep -aoi '<Representation' "$B" | wc -l)" >> "$OUT"
    echo "sample=$(tr '\n' ' ' < "$B" | sed 's/[[:space:]]\+/ /g' | cut -c1-420)" >> "$OUT"
  else
    echo "mpd=no" >> "$OUT"
    echo "sample=$(head -c 240 "$B" 2>/dev/null | tr '\n' ' ')" >> "$OUT"
  fi
  rm -f "$H" "$B"
done

echo >> "$OUT"
echo "NOTE=read-only reachability/manifest inspection; no credentials, tokens, or license requests" >> "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-amigonly-dash-probe.txt" || true
fi

cat "$OUT"
