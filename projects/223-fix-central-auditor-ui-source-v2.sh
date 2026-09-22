#!/usr/bin/env bash
set -euo pipefail

SRC=/home/ubuntu/Central/app/server.js
CADDY=/etc/caddy/Caddyfile
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/central-auditor-nav-v2-$STAMP
mkdir -p "$BACKUP"

echo "=== 1. VERIFY REAL CENTRAL SOURCE ==="
test -f "$SRC"
cp -a "$SRC" "$BACKUP/server.js.before"
grep -q '</body>' "$SRC" || grep -q '</html>' "$SRC"
echo CENTRAL_REAL_UI_SOURCE_OK
echo "source=$SRC"

echo "=== 2. CLEAN ACCIDENTAL PATCH FROM BENCH FIXTURE IF PRESENT ==="
WRONG=/home/ubuntu/central-bench/apk-test/decoded/assets/test1.html
if [ -f "$WRONG" ] && grep -q 'CENTRAL_AUDITOR_NAV_V1' "$WRONG"; then
  cp -a "$WRONG" "$BACKUP/test1.html.accidental"
  python3 - "$WRONG" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8",errors="ignore")
s=re.sub(r'\n?<!-- CENTRAL_AUDITOR_NAV_V1 -->.*?<a id="centralAuditorFab".*?</a>\n?','\n',s,flags=re.S)
p.write_text(s,encoding="utf-8")
print("ACCIDENTAL_BENCH_PATCH_REMOVED")
PY
else
  echo NO_ACCIDENTAL_BENCH_PATCH_FOUND
fi

echo "=== 3. PATCH REAL CENTRAL UI ==="
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")
marker="CENTRAL_AUDITOR_NAV_V2"
if marker in s:
    print("CENTRAL_AUDITOR_NAV_V2_ALREADY_PRESENT")
    raise SystemExit(0)

snippet=r'''
<!-- CENTRAL_AUDITOR_NAV_V2 -->
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
else:
    raise SystemExit("CENTRAL_REAL_UI_HTML_ANCHOR_NOT_FOUND")
p.write_text(s,encoding="utf-8")
print("CENTRAL_AUDITOR_NAV_V2_PATCH_OK")
PY

echo "=== 4. RESTART CENTRAL NODE SERVICE ==="
UNIT=""
PID=$(sudo lsof -t -iTCP:8090 -sTCP:LISTEN 2>/dev/null | head -n1 || true)
if [ -n "$PID" ] && [ -r "/proc/$PID/cgroup" ]; then
  UNIT=$(sed -n 's#^.*/\([^/]*\.service\)$#\1#p' "/proc/$PID/cgroup" | head -n1 || true)
fi
if [ -z "$UNIT" ]; then
  for u in central-backend.service central.service; do
    if systemctl status "$u" >/dev/null 2>&1; then UNIT="$u"; break; fi
  done
fi
if [ -n "$UNIT" ]; then
  echo "unit=$UNIT"
  systemctl restart "$UNIT"
else
  echo CENTRAL_UI_SYSTEMD_UNIT_NOT_FOUND
  exit 1
fi

for i in $(seq 1 30); do
  if curl -fsS --max-time 3 https://cen-tral.duckdns.org/central/ >/tmp/central-home-v2.html 2>/dev/null; then break; fi
  sleep 1
done

echo "=== 5. VERIFY PUBLIC HOME ENTRY ==="
grep -q 'CENTRAL_AUDITOR_NAV_V2' /tmp/central-home-v2.html
grep -q 'href="/central/auditor/"' /tmp/central-home-v2.html
echo CENTRAL_HOME_AUDITOR_ENTRY_V2_OK

echo "=== 6. VERIFY NESTED AUDITOR ==="
AUD=$(curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/)
grep -q 'Central · APK / XAPK' <<<"$AUD"
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo CENTRAL_NESTED_AUDITOR_PUBLIC_V2_OK

echo CENTRAL_AUDITOR_NAV_V2_READY
echo "URL=https://cen-tral.duckdns.org/central/"
echo "AUDITOR=https://cen-tral.duckdns.org/central/auditor/"
echo "backup=$BACKUP"
