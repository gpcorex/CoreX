#!/usr/bin/env bash
set -euo pipefail

mkdir -p /var/log/conector /var/lib/conector

cat >/usr/local/sbin/conector-publish-result <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 2 ] || { echo 'usage: conector-publish-result <local_file> <repo_path>' >&2; exit 2; }
LOCAL_FILE="$1"
REPO_PATH="$2"
BASE=/opt/corex/repo
LOCK=/run/conector-publish-result.lock
[ -f "$LOCAL_FILE" ] || { echo LOCAL_FILE_MISSING; exit 3; }
case "$REPO_PATH" in /*|*'..'*) echo INVALID_REPO_PATH; exit 4;; esac
exec 9>"$LOCK"
flock -w 20 9 || { echo PUBLISH_LOCK_BUSY; exit 5; }
GIT=(git -c safe.directory="$BASE" -C "$BASE")
"${GIT[@]}" fetch origin results >/dev/null 2>&1 || true
if "${GIT[@]}" rev-parse --verify origin/results >/dev/null 2>&1; then BASE_REF=origin/results; else BASE_REF=origin/main; fi
PARENT="$("${GIT[@]}" rev-parse "$BASE_REF")"
PARENT_TREE="$("${GIT[@]}" rev-parse "$BASE_REF^{tree}")"
IDX="$(mktemp)"
rm -f "$IDX"
trap 'rm -f "$IDX"' EXIT
GIT_INDEX_FILE="$IDX" "${GIT[@]}" read-tree "$BASE_REF"
BLOB="$("${GIT[@]}" hash-object -w "$LOCAL_FILE")"
GIT_INDEX_FILE="$IDX" "${GIT[@]}" update-index --add --cacheinfo 100644 "$BLOB" "$REPO_PATH"
TREE="$(GIT_INDEX_FILE="$IDX" "${GIT[@]}" write-tree)"
if [ "$TREE" = "$PARENT_TREE" ]; then echo UNCHANGED; exit 0; fi
export GIT_AUTHOR_NAME='Conector VM' GIT_AUTHOR_EMAIL='conector-vm@local' GIT_COMMITTER_NAME='Conector VM' GIT_COMMITTER_EMAIL='conector-vm@local'
COMMIT="$(printf 'Conector result: %s\n' "$REPO_PATH" | "${GIT[@]}" commit-tree "$TREE" -p "$PARENT")"
"${GIT[@]}" push origin "$COMMIT:refs/heads/results" >/dev/null 2>&1 && echo "PUBLISHED $COMMIT" || { echo PUSH_FAILED; exit 6; }
EOF
chmod 755 /usr/local/sbin/conector-publish-result

if [ -x /usr/local/sbin/conector-snapshot ]; then
  /usr/local/sbin/conector-snapshot || true
  /usr/local/sbin/conector-publish-result /var/lib/conector/status.txt vm-results/status.txt || true
fi

echo CONECTOR_GIT_RETURN_READY
