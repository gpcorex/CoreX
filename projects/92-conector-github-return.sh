#!/usr/bin/env bash
set -euo pipefail

ETC="/etc/conector"
BIN="/usr/local/sbin/conector-publish-result"
mkdir -p "$ETC"
chmod 700 "$ETC"

cat >"$BIN" <<'PY'
#!/usr/bin/env python3
import base64, json, os, sys, urllib.request, urllib.error

if len(sys.argv) != 3:
    print("usage: conector-publish-result <local_file> <repo_path>", file=sys.stderr)
    sys.exit(2)

local_file, repo_path = sys.argv[1], sys.argv[2]
token_path = "/etc/conector/github.token"
if not os.path.isfile(token_path):
    print("MISSING_TOKEN")
    sys.exit(3)

token = open(token_path).read().strip()
if not token:
    print("EMPTY_TOKEN")
    sys.exit(4)

repo = "gpcorex/CoreX"
branch = "results"
api = f"https://api.github.com/repos/{repo}/contents/{repo_path}"
headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "Conector"
}

sha = None
req = urllib.request.Request(api + f"?ref={branch}", headers=headers)
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        data = json.load(r)
        sha = data.get("sha")
except urllib.error.HTTPError as e:
    if e.code != 404:
        raise

content = base64.b64encode(open(local_file, "rb").read()).decode()
payload = {
    "message": f"Conector result: {repo_path}",
    "content": content,
    "branch": branch,
}
if sha:
    payload["sha"] = sha

req = urllib.request.Request(
    api,
    data=json.dumps(payload).encode(),
    headers={**headers, "Content-Type": "application/json"},
    method="PUT"
)
with urllib.request.urlopen(req, timeout=30) as r:
    out = json.load(r)
print("PUBLISHED", out.get("commit", {}).get("sha", ""))
PY

chmod 755 "$BIN"

cat >/etc/systemd/system/conector-publish-health.service <<'EOF'
[Unit]
Description=Publish Conector sanitized health result
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc '/usr/local/sbin/conector-health-snapshot && /usr/local/sbin/conector-publish-result /var/lib/conector/health.txt vm-results/health.txt'
EOF

cat >/usr/local/sbin/conector-health-snapshot <<'EOF'
#!/usr/bin/env bash
set -u
mkdir -p /var/lib/conector
{
  echo "CONECTOR_HEALTH"
  echo "generated_at=$(date -Is)"
  echo "host=$(hostname)"
  echo "repo_head=$(git -C /opt/corex/repo rev-parse HEAD 2>/dev/null || true)"
  echo "conector_sync=$(systemctl is-active conector-sync.timer 2>/dev/null || true)"
  echo "conector_ops=$(systemctl is-active conector-central-ops.timer 2>/dev/null || true)"
  echo "central_backend=$(systemctl is-active central-backend 2>/dev/null || true)"
  echo "caddy=$(systemctl is-active caddy 2>/dev/null || true)"
} >/var/lib/conector/health.txt
chmod 600 /var/lib/conector/health.txt
EOF
chmod 755 /usr/local/sbin/conector-health-snapshot

cat >/etc/systemd/system/conector-publish-health.timer <<'EOF'
[Unit]
Description=Publish Conector health every minute

[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=5
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable conector-publish-health.timer

echo "CONECTOR_GITHUB_RETURN_CHANNEL_PREPARED"
echo "Token pendiente en /etc/conector/github.token"
