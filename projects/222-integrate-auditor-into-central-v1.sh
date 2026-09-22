#!/usr/bin/env bash
set -euo pipefail

CADDY=/etc/caddy/Caddyfile
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/central-auditor-nav-v1-$STAMP
mkdir -p "$BACKUP"

echo "=== 1. ADD AUDITOR UNDER /central/ ==="
if ! grep -q 'route /central/auditor/\\*' "$CADDY"; then
python3 - <<'PY'
from pathlib import Path
p=Path("/etc/caddy/Caddyfile")
s=p.read_text(encoding="utf-8")
block='''    route /central/auditor {
        redir /central/auditor/ 308
    }

    route /central/auditor/* {
        uri strip_prefix /central/auditor
        reverse_proxy 127.0.0.1:8792
    }

'''
for anchor in ('    route /central/* {\n','    route /central {\n','    route {\n'):
    if anchor in s:
        s=s.replace(anchor,block+anchor,1)
        break
else:
    pos=s.rfind('}')
    if pos<0: raise SystemExit("CADDY_SITE_BLOCK_NOT_FOUND")
    s=s[:pos]+block+s[pos:]
p.write_text(s,encoding="utf-8")
PY
fi
caddy validate --config "$CADDY"
systemctl reload caddy
echo CENTRAL_AUDITOR_NESTED_ROUTE_OK

echo "=== 2. DISCOVER CENTRAL UI SOURCE ==="
PID=$(sudo lsof -t -iTCP:8090 -sTCP:LISTEN 2>/dev/null | head -n1 || true)
if [ -z "$PID" ]; then
  echo CENTRAL_UI_PID_NOT_FOUND
  exit 1
fi
CMD=$(tr '\\0' ' ' </proc/$PID/cmdline 2>/dev/null || true)
CWD=$(readlink -f /proc/$PID/cwd 2>/dev/null || true)
echo "pid=$PID"
echo "cwd=$CWD"
echo "cmd=$CMD"

SRC=""
for token in $CMD; do
  case "$token" in
    *.py|*.js|*.mjs|*.cjs)
      if [ -f "$token" ]; then SRC="$token"; break; fi
      if [ -n "$CWD" ] && [ -f "$CWD/$token" ]; then SRC="$CWD/$token"; break; fi
      ;;
  esac
done

if [ -z "$SRC" ]; then
  for base in "$CWD" /srv/apps/central /home/ubuntu/Central; do
    [ -d "$base" ] || continue
    cand=$(grep -RIl --exclude-dir=backups --exclude='*.log' -m1 '</body>' "$base" 2>/dev/null | head -n1 || true)
    if [ -n "$cand" ]; then SRC="$cand"; break; fi
  done
fi

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  echo CENTRAL_UI_SOURCE_NOT_FOUND
  exit 1
fi
echo "source=$SRC"
cp -a "$SRC" "$BACKUP/$(basename "$SRC").before"
echo CENTRAL_UI_SOURCE_DISCOVERED_OK

echo "=== 3. ADD AUDITOR ENTRY TO CENTRAL HOME ==="
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")
marker="CENTRAL_AUDITOR_NAV_V1"
if marker in s:
    print("CENTRAL_AUDITOR_NAV_ALREADY_PRESENT")
    raise SystemExit(0)
snippet=r'''
<!-- CENTRAL_AUDITOR_NAV_V1 -->
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
    raise SystemExit("CENTRAL_HTML_BODY_ANCHOR_NOT_FOUND")
p.write_text(s,encoding="utf-8")
print("CENTRAL_AUDITOR_NAV_PATCH_OK")
PY

echo "=== 4. RESTART CENTRAL UI OWNER ==="
UNIT=""
for u in central-backend.service central.service; do
  if systemctl status "$u" >/dev/null 2>&1; then UNIT="$u"; break; fi
done
if [ -n "$UNIT" ]; then
  systemctl restart "$UNIT"
else
  kill -HUP "$PID" 2>/dev/null || true
  sleep 2
fi

for i in $(seq 1 30); do
  if curl -fsS --max-time 2 https://cen-tral.duckdns.org/central/ >/tmp/central-home-nav.html 2>/dev/null; then break; fi
  sleep 1
done

echo "=== 5. VERIFY PUBLIC CENTRAL + NESTED AUDITOR ==="
HOMEHTML=$(curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/)
grep -q 'CENTRAL_AUDITOR_NAV_V1' <<<"$HOMEHTML"
grep -q 'href="/central/auditor/"' <<<"$HOMEHTML"
echo CENTRAL_HOME_AUDITOR_ENTRY_OK

AUDHTML=$(curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/)
grep -q 'Central · APK / XAPK' <<<"$AUDHTML"
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo CENTRAL_NESTED_AUDITOR_PUBLIC_OK

echo CENTRAL_AUDITOR_NAV_V1_READY
echo "URL=https://cen-tral.duckdns.org/central/"
echo "AUDITOR=https://cen-tral.duckdns.org/central/auditor/"
echo "source=$SRC"
echo "backup=$BACKUP"
