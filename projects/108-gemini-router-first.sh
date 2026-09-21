#!/usr/bin/env bash
set -euo pipefail

MAIN=/home/ubuntu/Gemini/app/main.py
STAMP=$(date +%Y%m%d-%H%M%S)
cp -a "$MAIN" "$MAIN.bak-router-first-$STAMP"

python3 - <<'PY'
import ast
from pathlib import Path

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

if "ROUTER_FIRST_NORMAL_CHAT" in s:
    print("ROUTER_FIRST_ALREADY_PRESENT")
    raise SystemExit(0)

tree=ast.parse(s)
funcs={}
for n in tree.body:
    if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)):
        funcs[n.name]=n

direct=funcs.get("api_chat_direct")
auto=funcs.get("api_chat_auto")
if direct is None:
    raise SystemExit("API_CHAT_DIRECT_NOT_FOUND")
if auto is None:
    raise SystemExit("API_CHAT_AUTO_NOT_FOUND")

auto_src=ast.get_source_segment(s,auto) or ""
router_signals=("routed_answer","router","call_provider","RATE_LIMIT","provider")
if not any(x in auto_src for x in router_signals):
    raise SystemExit("AUTO_ROUTE_DOES_NOT_LOOK_ROUTED")

lines=s.splitlines(True)
insert_at=direct.body[0].lineno-1
indent=" " * direct.body[0].col_offset

if isinstance(auto,ast.AsyncFunctionDef):
    call=f"{indent}    return await api_chat_auto(body)\n"
else:
    call=f"{indent}    return api_chat_auto(body)\n"

block=(
    f"{indent}# ROUTER_FIRST_NORMAL_CHAT: normal chat bypasses direct Gemini.\n"
    f"{indent}# Programming/VM requests continue through Central below.\n"
    f"{indent}if not _looks_like_programming_request((body.message or '').strip()):\n"
    + call +
    "\n"
)

lines.insert(insert_at,block)
p.write_text("".join(lines),encoding="utf-8")
print("ROUTER_FIRST_PATCH_OK")
print("AUTO_KIND="+("async" if isinstance(auto,ast.AsyncFunctionDef) else "sync"))
PY

python3 -m py_compile "$MAIN"

systemctl restart gemini-backend.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/gem-router-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done

echo "=== HEALTH ==="
cat /tmp/gem-router-health.json

echo
echo "=== ROUTER FIRST ==="
grep -n -A4 -B2 'ROUTER_FIRST_NORMAL_CHAT' "$MAIN"

echo
echo GEMINI_ROUTER_FIRST_READY
