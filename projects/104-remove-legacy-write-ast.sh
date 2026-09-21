#!/usr/bin/env bash
set -euo pipefail

MAIN=/home/ubuntu/Gemini/app/main.py
STAMP=$(date +%Y%m%d-%H%M%S)
cp -a "$MAIN" "$MAIN.bak-legacy-write-ast-$STAMP"

python3 - <<'PY'
import ast
from pathlib import Path

p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")
tree=ast.parse(s)

target=None

class Finder(ast.NodeVisitor):
    def visit_AsyncFunctionDef(self,node):
        global target
        if node.name!="api_chat_direct":
            return
        for child in node.body:
            if isinstance(child, ast.If):
                found=False
                for sub in ast.walk(child):
                    if isinstance(sub, ast.ImportFrom) and sub.module in ("central_executor_bridge","app.central_executor_bridge"):
                        found=True
                        break
                if found:
                    target=child
                    return

Finder().visit(tree)

if target is None:
    print("LEGACY_WRITE_IF_NOT_FOUND")
else:
    lines=s.splitlines(True)
    start=target.lineno-1
    end=target.end_lineno
    del lines[start:end]
    p.write_text("".join(lines),encoding="utf-8")
    print(f"LEGACY_WRITE_IF_REMOVED lines={target.lineno}-{target.end_lineno}")
PY

python3 -m py_compile "$MAIN"
systemctl restart gemini-backend.service

for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/gem-health.json 2>/dev/null && break
  sleep 1
done

echo "=== GEMINI HEALTH ==="
cat /tmp/gem-health.json || true
echo

echo "=== LEGACY IMPORT CHECK ==="
grep -n "central_executor_bridge" "$MAIN" || true
echo

echo "=== E2E WRITE ==="
set +e
curl -sS --max-time 420   -H 'Content-Type: application/json'   -d '{"message":"Creá /tmp/gemini-central-e2e.txt con el texto GEMINI_CENTRAL_E2E_OK","conversation_id":"central-e2e-test-3"}'   http://127.0.0.1:8791/api/chat/direct
RC=$?
set -e
echo
echo "curl_rc=$RC"

echo "=== FILE VERIFY ==="
if [ -f /tmp/gemini-central-e2e.txt ]; then
  cat /tmp/gemini-central-e2e.txt
else
  echo FILE_NOT_CREATED
fi

echo "=== RECENT GEMINI LOGS ==="
journalctl -u gemini-backend.service -n 100 --no-pager || true

echo GEMINI_LEGACY_WRITE_AST_DONE
