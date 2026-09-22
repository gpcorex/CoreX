#!/usr/bin/env bash
set -u

# Read-only audit. It intentionally does not restart, write config, install,
# enable/disable, or modify any service. Output only.
export LC_ALL=C

section(){ printf '\n===== %s =====\n' "$1"; }
run(){ printf '\n$ %s\n' "$*"; "$@" 2>&1 || true; }

section "IDENTITY"
run date -Is
run hostname
run whoami
run uname -a
run bash -lc 'grep -E "^(PRETTY_NAME|VERSION=)" /etc/os-release'
run uptime

section "RESOURCES"
run free -h
run swapon --show
run df -h /
run bash -lc 'ps -eo pid,user,comm,%cpu,%mem,rss,args --sort=-rss | head -20'

section "LISTENING PORTS"
run bash -lc 'ss -ltnp | grep -E ":(80|443|8090|8091|8791|18789|6080|5901)\b" || true'

section "SYSTEM SERVICES"
for s in caddy central-jobs-api gemini-backend android-runtime android-novnc; do
  printf '\n-- %s --\n' "$s"
  systemctl is-enabled "$s.service" 2>&1 || true
  systemctl is-active "$s.service" 2>&1 || true
  systemctl show "$s.service" -p ActiveState -p SubState -p MainPID -p ExecMainStatus -p NRestarts -p MemoryCurrent -p CPUUsageNSec 2>&1 || true
done

section "USER SERVICES"
UIDU="$(id -u ubuntu 2>/dev/null || id -u)"
export XDG_RUNTIME_DIR="/run/user/$UIDU"
for s in openclaw-gateway; do
  printf '\n-- %s --\n' "$s"
  systemctl --user is-enabled "$s.service" 2>&1 || true
  systemctl --user is-active "$s.service" 2>&1 || true
  systemctl --user show "$s.service" -p ActiveState -p SubState -p MainPID -p ExecMainStatus -p NRestarts -p MemoryCurrent -p CPUUsageNSec 2>&1 || true
done

section "TIMERS"
run bash -lc 'systemctl list-timers --all --no-pager | grep -Ei "corex|conector|central|gemini|openclaw" || true'
run bash -lc 'systemctl --user list-timers --all --no-pager | grep -Ei "corex|conector|central|gemini|openclaw" || true'

section "FILESYSTEM TOP LEVEL"
for d in /home/ubuntu/Central /home/ubuntu/Gemini /home/ubuntu/.openclaw /srv/apps /opt/corex/repo; do
  printf '\n-- %s --\n' "$d"
  if [ -e "$d" ]; then
    du -sh "$d" 2>&1 || true
    find "$d" -maxdepth 2 -mindepth 1 -printf '%y %u:%g %s %p\n' 2>/dev/null | sort | head -160
  else
    echo MISSING
  fi
done

section "GIT"
if [ -d /opt/corex/repo/.git ]; then
  run git -C /opt/corex/repo status --short --branch
  run git -C /opt/corex/repo log -8 --oneline --decorate
  run git -C /opt/corex/repo remote -v
fi

section "CENTRAL RUNTIME"
for f in /home/ubuntu/Central/runtime/jobs_api.py /home/ubuntu/Central/runtime/executor.js; do
  printf '\n-- %s --\n' "$f"
  if [ -f "$f" ]; then
    stat -c '%U:%G %a %s bytes %y' "$f"
    grep -nE 'DIRECT|OPENCLAW|model|--model|api/jobs|agent/action|CENTRAL_STATUS' "$f" 2>/dev/null | head -120 || true
  else
    echo MISSING
  fi
done
run curl -fsS --max-time 5 http://127.0.0.1:8091/api/health

section "GEMINI LEGACY BACKEND"
if [ -f /home/ubuntu/Gemini/app/main.py ]; then
  stat -c '%U:%G %a %s bytes %y' /home/ubuntu/Gemini/app/main.py
  echo "-- architecture markers --"
  grep -nE 'OPENCLAW_ONLY|ROUTER_ONLY|NATIVE_PROGRAMMER|routed_answer|call_openai|call_gemini|CENTRAL_JOBS_BASE|api/chat/direct|api/providers' /home/ubuntu/Gemini/app/main.py 2>/dev/null | head -220 || true
  echo "-- duplicate definitions counts --"
  for n in routed_answer call_openai call_gemini api_chat_direct; do
    printf '%s=' "$n"
    grep -cE "^async def $n\b|^def $n\b" /home/ubuntu/Gemini/app/main.py 2>/dev/null || true
  done
else
  echo MISSING
fi
run curl -fsS --max-time 5 http://127.0.0.1:8791/api/health

section "OPENCLAW EFFECTIVE CONFIG (SANITIZED)"
python3 - <<'PY'
import json
from pathlib import Path
p=Path('/home/ubuntu/.openclaw/openclaw.json')
if not p.exists():
    print('MISSING',p); raise SystemExit
d=json.loads(p.read_text())
out={}
out['gateway']=d.get('gateway',{})
# remove token if present
if isinstance(out['gateway'],dict):
    auth=out['gateway'].get('auth')
    if isinstance(auth,dict) and 'token' in auth:
        auth=dict(auth); auth['token']='***REDACTED***'; out['gateway']=dict(out['gateway']); out['gateway']['auth']=auth
out['agents']=d.get('agents',{})
out['tools']=d.get('tools',{})
providers={}
for name,cfg in (d.get('models',{}).get('providers',{}) or {}).items():
    if not isinstance(cfg,dict):
        providers[name]=str(type(cfg).__name__); continue
    providers[name]={
      'baseUrl':cfg.get('baseUrl'),
      'api':cfg.get('api'),
      'apiKey':'***SET***' if cfg.get('apiKey') else None,
      'models':[x.get('id') if isinstance(x,dict) else x for x in (cfg.get('models') or [])],
    }
out['modelProviders']=providers
print(json.dumps(out,ensure_ascii=False,indent=2))
PY

section "OPENCLAW ENV NAMES ONLY"
if [ -f /home/ubuntu/.openclaw/.env ]; then
  sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1=***SET***/p' /home/ubuntu/.openclaw/.env | sort
else
  echo MISSING
fi

section "OPENCLAW HTTP"
if [ -s /home/ubuntu/.openclaw/gateway.token ]; then
  TOK="$(cat /home/ubuntu/.openclaw/gateway.token)"
  run curl -fsS --max-time 5 -H "Authorization: Bearer $TOK" http://127.0.0.1:18789/v1/models
else
  echo TOKEN_FILE_MISSING
fi

section "OPENCLAW RECENT ERRORS"
run bash -lc 'journalctl --user -u openclaw-gateway.service --since "-3 hours" --no-pager | grep -Ei "error|failed|timeout|slow|fallback|rate.limit|429|400|invalid|sqlite|liveness" | tail -160'

section "CADDY ROUTES"
if [ -f /etc/caddy/Caddyfile ]; then
  grep -nE 'gemini|openclaw|8090|8091|8791|18789|reverse_proxy|route ' /etc/caddy/Caddyfile 2>/dev/null | head -180 || true
else
  echo MISSING
fi

section "WRITE AUTHORITY"
for f in /var/lib/conector/write-authority /var/lib/conector/openclaw-status.txt; do
  printf '\n-- %s --\n' "$f"
  [ -f "$f" ] && cat "$f" || echo MISSING
done

section "RECENT CENTRAL/GEMINI ERRORS"
run bash -lc 'journalctl -u central-jobs-api.service --since "-3 hours" --no-pager | tail -120'
run bash -lc 'journalctl -u gemini-backend.service --since "-3 hours" --no-pager | tail -120'

section "AUDIT COMPLETE"
echo CENTRAL_READONLY_AUDIT_COMPLETE
