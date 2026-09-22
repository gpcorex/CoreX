#!/usr/bin/env bash
set -euo pipefail

CENTRAL=/home/ubuntu/Central
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/permissions-policy-v1-$STAMP
mkdir -p "$BACKUP"

echo "=== 1. INSTALL ACL SUPPORT ==="
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq acl >/tmp/central-acl-install.log 2>&1 || {
  cat /tmp/central-acl-install.log
  exit 1
}
command -v setfacl >/dev/null
command -v getfacl >/dev/null
echo CENTRAL_ACL_TOOLING_OK

echo "=== 2. NORMALIZE CURRENT CENTRAL TREE ==="
sudo mkdir -p "$CENTRAL"
sudo chown -R ubuntu:ubuntu "$CENTRAL"
sudo find "$CENTRAL" -type d -exec chmod u+rwx,g+rx {} +
sudo find "$CENTRAL" -type f -exec chmod u+rw,g+r {} +
echo CENTRAL_CURRENT_OWNERSHIP_OK

echo "=== 3. INSTALL PERSISTENT PERMISSION POLICY ==="
# Every existing directory grants ubuntu rwx now and by inheritance.
sudo find "$CENTRAL" -type d -exec setfacl -m u:ubuntu:rwx,m:rwx {} +
sudo find "$CENTRAL" -type d -exec setfacl -d -m u:ubuntu:rwx,m:rwx {} +
# Existing files remain writable by ubuntu; X is preserved only where already executable.
sudo find "$CENTRAL" -type f -exec setfacl -m u:ubuntu:rwX,m:rwX {} +
echo CENTRAL_DEFAULT_ACL_OK

echo "=== 4. INSTALL PERMISSION POLICY CHECK ==="
cat >"$CENTRAL/permissions-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT=/home/ubuntu/Central
FAIL=0

echo "owner=$(stat -c '%U:%G' "$ROOT")"

TMP="$ROOT/.permission-probe-$$"
sudo -u ubuntu mkdir -p "$TMP/a/b"
sudo -u ubuntu sh -c "printf 'ubuntu-write-ok\n' > '$TMP/a/b/from-ubuntu.txt'"

# Simulate a future installer/test executed as root.
sudo sh -c "mkdir -p '$TMP/root-created' && printf 'root-created\n' > '$TMP/root-created/file.txt'"

# ubuntu must still be able to modify root-created content because of inherited ACL.
sudo -u ubuntu sh -c "printf 'ubuntu-appended\n' >> '$TMP/root-created/file.txt'"
sudo -u ubuntu sh -c "mkdir -p '$TMP/root-created/child'"

grep -q ubuntu-appended "$TMP/root-created/file.txt" || FAIL=1
test -w "$TMP/root-created/file.txt" || FAIL=1

rm -rf "$TMP"

if [ "$FAIL" -ne 0 ]; then
  echo CENTRAL_PERMISSION_POLICY_FAILED
  exit 1
fi

echo CENTRAL_ROOT_CREATED_CONTENT_WRITABLE_BY_UBUNTU_OK
echo CENTRAL_PERMISSION_POLICY_OK
EOF
sudo chown ubuntu:ubuntu "$CENTRAL/permissions-check.sh"
sudo chmod 755 "$CENTRAL/permissions-check.sh"
sudo setfacl -m u:ubuntu:rwx "$CENTRAL/permissions-check.sh"

echo "=== 5. VERIFY ROOT -> UBUNTU INHERITANCE ==="
sudo "$CENTRAL/permissions-check.sh"

echo "=== 6. SHOW EFFECTIVE ACL ==="
getfacl -p "$CENTRAL" | sed -n '1,24p'

echo CENTRAL_PERMISSIONS_POLICY_V1_READY
echo "backup=$BACKUP"
