#!/usr/bin/env bash
set -euo pipefail

mkdir -p /srv/apps
cat >/srv/apps/PUENTE_OK.txt <<EOF
PUENTE_OK
deployed_at=$(date -Is)
host=$(hostname)
commit=$(git -C /opt/corex/repo rev-parse HEAD)
EOF
