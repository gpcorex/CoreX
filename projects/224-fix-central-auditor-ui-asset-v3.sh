#!/usr/bin/env bash
set -euo pipefail

APP=/home/ubuntu/Central/app
CADDY=/etc/caddy/Caddyfile
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/central-auditor-nav-v3-$STAMP
mkdir -p "$BACKUP"

echo "=== 1. VERIFY CENTRAL APP ==="
test -d "$APP"
test -f "$APP/server.js"
echo CENTRAL_APP_PRESENT_OK

echo "=== 2. FIND REAL UI ASSET SAFELY ==="
LIVE=/tmp/central-live-$STAMP.html
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/ > "$LIVE"
test -s "$LIVE"

CANDIDATES=/tmp/central-ui-candidates-$STAMP.txt
find "$APP" -type f \( -name '*.html' -o -name '*.htm' -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \)   ! -path '*/node_modules/*' ! -path '*/backups/*' -print > "$CANDIDATES"

SRC=""
# Prefer files with obvious Central UI text and HTML structure.
while IFS= read -r f; do
  if grep -qiE '<html|<!doctype|<body' "$f" 2>/dev/null && grep -qiE 'central|conversaci|chat' "$f" 2>/dev/null; then
    SRC="$f"
    break
  fi
done < "$CANDIDATES"

# If server.js references a concrete html file, prefer that.
REF=$(grep -Eo '["'"''][^"'"'']+\.html["'"'']' "$APP/server.js" 2>/dev/null | head -n1 | tr -d '"''' || true)
if [ -n "$REF" ]; then
  if [ -f "$APP/$REF" ]; then SRC="$APP/$REF"; fi
  if [ -f "$REF" ]; then SRC="$REF"; fi
fi

if [ -z "$SRC" ]; then
  echo CENTRAL_UI_ASSET_NOT_FOUND
  echo "--- server.js hints ---"
  grep -nEi 'sendFile|readFile|static|index|html|public|dist|build' "$APP/server.js" | head -n80 || true
  exit 1
fi

echo "source=$SRC"
cp -a "$SRC" "$BACKUP/$(basename "$SRC").before"
echo CENTRAL_REAL_UI_ASSET_FOUND_OK

echo "=== 3. PATCH AUDITOR ENTRY ==="
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8",errors="ignore")
marker="CENTRAL_AUDITOR_NAV_V3"
if marker in s:
    print("CENTRAL_AUDITOR_NAV_V3_ALREADY_PRESENT")
    raise SystemExit(0)

snippet=r'''
<!-- CENTRAL_AUDITOR_NAV_V3 -->
<style>
#centralAuditorFab{position:fixed;right:18px;top:14px;z-index:9998;text-decoration:none;color:#eef2f7;background:#1b202b;border:1px solid #394356;border-radius:12px;padding:9px 13px;font:600 13px system-ui,-apple-system,Segoe UI,Roboto,sans-serif;box-shadow:0 6px 22px #0005}
#centralAuditorFab:hover{background:#242b39}
@media(max-width:760px){#centralAuditorFab{right:10px;top:10px;padding:8px 11px}}
</style>
<a id="centralAuditorFab" href="/central/auditor/" title="Abrir Auditor">Auditor</a>
'''
if "</body>" in s:
    s=s.replace("</body>",snippet+"\n</body>",1)
elif "</html>" in s:
    s=s.replace("</html>",snippet+"\n</html>",1)
elif "<body" in s.lower():
    m=re.search(r'(?i)<body[^>]*>',s)
    if not m: raise SystemExit("BODY_TAG_PARSE_FAILED")
    s=s[:m.end()]+snippet+s[m.end():]
else:
    raise SystemExit("CENTRAL_UI_ASSET_HAS_NO_HTML_BODY")

p.write_text(s,encoding="utf-8")
print("CENTRAL_AUDITOR_NAV_V3_PATCH_OK")
PY

echo "=== 4. RESTART ACTUAL 8090 OWNER ==="
PID=$(sudo lsof -t -iTCP:8090 -sTCP:LISTEN 2>/dev/null | head -n1 || true)
if [ -z "$PID" ]; then
  echo CENTRAL_8090_PID_NOT_FOUND
  exit 1
fi
UNIT=$(sed -n 's#^.*/\([^/]*\.service\)$#\1#p' "/proc/$PID/cgroup" 2>/dev/null | head -n1 || true)
if [ -z "$UNIT" ]; then
  echo CENTRAL_8090_SYSTEMD_UNIT_NOT_FOUND
  cat "/proc/$PID/cgroup" 2>/dev/null || true
  exit 1
fi
echo "unit=$UNIT"
systemctl restart "$UNIT"

for i in $(seq 1 30); do
  if curl -fsS --max-time 3 https://cen-tral.duckdns.org/central/ >/tmp/central-home-v3.html 2>/dev/null; then break; fi
  sleep 1
done

echo "=== 5. VERIFY HOME + AUDITOR ==="
grep -q 'CENTRAL_AUDITOR_NAV_V3' /tmp/central-home-v3.html
grep -q 'href="/central/auditor/"' /tmp/central-home-v3.html
echo CENTRAL_HOME_AUDITOR_ENTRY_V3_OK

AUD=$(curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/)
grep -q 'Central · APK / XAPK' <<<"$AUD"
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo CENTRAL_NESTED_AUDITOR_PUBLIC_V3_OK

echo CENTRAL_AUDITOR_NAV_V3_READY
echo "URL=https://cen-tral.duckdns.org/central/"
echo "AUDITOR=https://cen-tral.duckdns.org/central/auditor/"
echo "source=$SRC"
echo "backup=$BACKUP"
