#!/usr/bin/env bash
set -euo pipefail

APP=/home/ubuntu/Central/app
CADDY=/etc/caddy/Caddyfile
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/central-auditor-nav-v4-$STAMP
mkdir -p "$BACKUP"

echo "=== 1. VERIFY CENTRAL + AUDITOR ROUTES ==="
test -f "$APP/server.js"
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/ >/tmp/central-live-v4.html
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo CENTRAL_AND_AUDITOR_ROUTES_OK

echo "=== 2. FIND ACTUAL CENTRAL UI SOURCE WITH PYTHON ==="
SRCFILE=/tmp/central-ui-source-v4.txt
python3 - "$APP" "$SRCFILE" <<'PY'
from pathlib import Path
import re,sys
app=Path(sys.argv[1])
out=Path(sys.argv[2])
server=app/"server.js"
s=server.read_text(encoding="utf-8",errors="ignore")

candidates=[]

# First: explicit HTML paths referenced by server.js.
for m in re.finditer(r"""['"]([^'"]+\.html?)['"]""",s,re.I):
    raw=m.group(1)
    for p in ((app/raw).resolve(),Path(raw)):
        if p.is_file() and str(p).startswith(str(app.resolve())):
            candidates.append(p)

# Then: likely UI/static files under the app tree.
for p in app.rglob("*"):
    if not p.is_file():
        continue
    parts=set(p.parts)
    if "node_modules" in parts or "backups" in parts:
        continue
    if p.suffix.lower() not in {".html",".htm",".js",".mjs",".cjs"}:
        continue
    candidates.append(p)

seen=set()
ranked=[]
for p in candidates:
    try:
        rp=p.resolve()
        if rp in seen: continue
        seen.add(rp)
        txt=p.read_text(encoding="utf-8",errors="ignore")
    except Exception:
        continue
    low=txt.lower()
    score=0
    if "<!doctype" in low: score+=10
    if "<html" in low: score+=10
    if "<body" in low: score+=10
    if "</body>" in low: score+=10
    if "central" in low: score+=5
    if "conversaci" in low or "nueva conversación" in low: score+=8
    if "api/" in low: score+=3
    if "8090" in low: score+=2
    if score:
        ranked.append((score,len(txt),p))

ranked.sort(key=lambda x:(-x[0],x[1]))
if not ranked:
    raise SystemExit("CENTRAL_UI_SOURCE_NOT_FOUND")

score,size,p=ranked[0]
out.write_text(str(p),encoding="utf-8")
print("CENTRAL_UI_SOURCE="+str(p))
print("CENTRAL_UI_SOURCE_SCORE="+str(score))
PY

SRC=$(cat "$SRCFILE")
test -f "$SRC"
cp -a "$SRC" "$BACKUP/$(basename "$SRC").before"
echo CENTRAL_REAL_UI_ASSET_FOUND_V4_OK
echo "source=$SRC"

echo "=== 3. PATCH REAL UI ==="
python3 - "$SRC" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8",errors="ignore")

marker="CENTRAL_AUDITOR_NAV_V4"
if marker in s:
    print("CENTRAL_AUDITOR_NAV_V4_ALREADY_PRESENT")
    raise SystemExit(0)

snippet=r'''
<!-- CENTRAL_AUDITOR_NAV_V4 -->
<style>
#centralAuditorFab{position:fixed;right:18px;top:14px;z-index:9998;text-decoration:none;color:#eef2f7;background:#1b202b;border:1px solid #394356;border-radius:12px;padding:9px 13px;font:600 13px system-ui,-apple-system,Segoe UI,Roboto,sans-serif;box-shadow:0 6px 22px #0005}
#centralAuditorFab:hover{background:#242b39}
@media(max-width:760px){#centralAuditorFab{right:10px;top:10px;padding:8px 11px}}
</style>
<a id="centralAuditorFab" href="/central/auditor/" title="Abrir Auditor">Auditor</a>
'''

low=s.lower()
if "</body>" in low:
    i=low.index("</body>")
    s=s[:i]+snippet+"\n"+s[i:]
elif "</html>" in low:
    i=low.index("</html>")
    s=s[:i]+snippet+"\n"+s[i:]
elif "<body" in low:
    m=re.search(r'(?i)<body[^>]*>',s)
    if not m: raise SystemExit("CENTRAL_BODY_PARSE_FAILED")
    s=s[:m.end()]+snippet+s[m.end():]
else:
    raise SystemExit("CENTRAL_UI_SOURCE_HAS_NO_BODY")

p.write_text(s,encoding="utf-8")
print("CENTRAL_AUDITOR_NAV_V4_PATCH_OK")
PY

echo "=== 4. RESTART ACTUAL PORT 8090 SERVICE ==="
PID=$(sudo lsof -t -iTCP:8090 -sTCP:LISTEN 2>/dev/null | head -n1 || true)
test -n "$PID"
UNIT=$(sed -n 's#^.*/\([^/]*\.service\)$#\1#p' "/proc/$PID/cgroup" 2>/dev/null | head -n1 || true)

if [ -n "$UNIT" ]; then
  echo "unit=$UNIT"
  systemctl restart "$UNIT"
else
  # Node may be launched by a wrapper not represented as a systemd unit.
  # In that case use the known Central service candidates only.
  for u in central-backend.service central.service; do
    if systemctl is-active "$u" >/dev/null 2>&1; then
      UNIT="$u"
      echo "unit=$UNIT"
      systemctl restart "$UNIT"
      break
    fi
  done
fi
test -n "$UNIT"

for i in $(seq 1 30); do
  if curl -fsS --max-time 3 https://cen-tral.duckdns.org/central/ >/tmp/central-home-v4.html 2>/dev/null; then break; fi
  sleep 1
done

echo "=== 5. VERIFY PUBLIC INTEGRATION ==="
grep -q 'CENTRAL_AUDITOR_NAV_V4' /tmp/central-home-v4.html
grep -q 'href="/central/auditor/"' /tmp/central-home-v4.html
echo CENTRAL_HOME_AUDITOR_ENTRY_V4_OK

curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/ | grep -q 'Central · APK / XAPK'
curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/api/health | grep -q '"ok": true'
echo CENTRAL_NESTED_AUDITOR_PUBLIC_V4_OK

echo CENTRAL_AUDITOR_NAV_V4_READY
echo "URL=https://cen-tral.duckdns.org/central/"
echo "AUDITOR=https://cen-tral.duckdns.org/central/auditor/"
echo "source=$SRC"
echo "backup=$BACKUP"
