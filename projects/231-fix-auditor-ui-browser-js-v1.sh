#!/usr/bin/env bash
set -euo pipefail

UI=/home/ubuntu/Central/auditor_ui_v1/server.py
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/auditor-ui-js-fix-v1-$STAMP
mkdir -p "$BACKUP"
cp -a "$UI" "$BACKUP/server.py.before"

echo "=== 1. REPAIR BROKEN JS NEWLINE LITERALS ==="
python3 - "$UI" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

# Repair literal newlines accidentally injected inside JavaScript single-quoted strings.
s=s.replace("st+'\n':'')", "st+'\\n':'')")
s=s.replace("r.stage_detail?'\n'+r.stage_detail:''", "r.stage_detail?'\\n'+r.stage_detail:''")

# Also repair actual newline characters between JS quotes if present.
s=s.replace("st+'\n':'')".replace("\\n","\n"), "st+'\\n':'')")
s=s.replace(("r.stage_detail?'\n'+r.stage_detail:''").replace("\\n","\n"),
            "r.stage_detail?'\\n'+r.stage_detail:''")

p.write_text(s,encoding="utf-8")
print("AUDITOR_UI_JS_NEWLINE_REPAIR_OK")
PY

python3 -m py_compile "$UI"
echo AUDITOR_UI_PYTHON_COMPILE_OK

echo "=== 2. EXTRACT AND SYNTAX-CHECK BROWSER JAVASCRIPT ==="
python3 - "$UI" > /tmp/auditor-ui-script.js <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text(encoding="utf-8")
m=re.search(r"INDEX=r'''(.*)'''\s*\n\s*if __name__",s,re.S)
if not m:
    raise SystemExit("INDEX_BLOCK_NOT_FOUND")
html=m.group(1)
scripts=re.findall(r"<script>(.*?)</script>",html,re.S|re.I)
if not scripts:
    raise SystemExit("SCRIPT_BLOCK_NOT_FOUND")
print("\n".join(scripts))
PY

node --check /tmp/auditor-ui-script.js
echo AUDITOR_UI_BROWSER_JS_SYNTAX_OK

echo "=== 3. ADD CLIENT BOOT MARKER ==="
python3 - "$UI" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")
marker="AUDITOR_UI_CLIENT_BOOT_V1"
if marker not in s:
    anchor="health()\nloadRuns()\n"
    repl="document.documentElement.dataset.auditorBoot='AUDITOR_UI_CLIENT_BOOT_V1'\nhealth()\nloadRuns()\n"
    if anchor not in s:
        raise SystemExit("CLIENT_BOOT_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,repl,1)
p.write_text(s,encoding="utf-8")
PY
python3 -m py_compile "$UI"
echo AUDITOR_UI_CLIENT_BOOT_MARKER_OK

echo "=== 4. RESTART SERVICE ==="
systemctl restart central-auditor-ui.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8792/api/health >/tmp/auditor-jsfix-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/auditor-jsfix-health.json
echo
systemctl is-active central-auditor-ui.service
echo AUDITOR_UI_JSFIX_SERVICE_OK

echo "=== 5. VERIFY PUBLIC HTML CONTAINS REPAIRED JS ==="
PUB=$(curl -fsS --max-time 20 https://cen-tral.duckdns.org/central/auditor/)
grep -q "AUDITOR_UI_CLIENT_BOOT_V1" <<<"$PUB"
grep -q "fetchTimed" <<<"$PUB"

printf '%s' "$PUB" | python3 -c 'import re,sys; h=sys.stdin.read(); s="\n".join(re.findall(r"<script>(.*?)</script>",h,re.S|re.I)); open("/tmp/auditor-public-script.js","w").write(s)'
node --check /tmp/auditor-public-script.js
echo AUDITOR_UI_PUBLIC_JS_SYNTAX_OK

echo CENTRAL_AUDITOR_UI_JS_FIX_V1_READY
echo "backup=$BACKUP"
