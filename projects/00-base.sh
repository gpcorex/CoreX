#!/usr/bin/env bash
set -euo pipefail

mkdir -p /srv/apps/{central,android-bridge,gemini,verita}
mkdir -p /var/log/corex

cat >/srv/apps/README.txt <<'EOF'
CoreX managed applications

/srv/apps/central
/srv/apps/android-bridge
/srv/apps/gemini
/srv/apps/verita

Do not store secrets in the Git repository.
Use /etc/corex/ for local credentials and environment files.
EOF
