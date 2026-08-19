#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/phase1.sh"
source "$ROOT_DIR/lib/phase3.sh"

nova_phase1_info() { :; }
nova_phase1_ok() { :; }
nova_phase1_error() { printf '%s\n' "$*" >&2; }

test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
fake_bin="$test_dir/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/getent" <<'EOF'
#!/bin/sh
case "$1:$2" in
  passwd:admin) printf '%s\n' 'admin:x:1001:1001::/home/admin:/bin/bash' ;;
  group:admin) printf '%s\n' 'admin:x:1001:' ;;
  *) exit 2 ;;
esac
EOF
cat >"$fake_bin/id" <<'EOF'
#!/bin/sh
printf '%s\n' 'admin sudo docker'
EOF
chmod +x "$fake_bin/getent" "$fake_bin/id"

PATH="$fake_bin:$PATH" nova_phase3_validate_admin_user

if grep -Fq 'UID/GID 1000' "$ROOT_DIR/lib/phase3.sh"; then
  printf '%s\n' 'phase3 still requires UID/GID 1000' >&2
  exit 1
fi
grep -Fq 'dpkg --configure -a' "$ROOT_DIR/lib/phase3.sh"
grep -Fq 'apt-get -f install -y' "$ROOT_DIR/lib/phase3.sh"
if grep -Eq 'rm[[:space:]].*/var/lib/docker|rm[[:space:]].*docker_data' "$ROOT_DIR/lib/phase3.sh"; then
  printf '%s\n' 'phase3 contains destructive Docker data removal' >&2
  exit 1
fi

printf '%s\n' 'Phase 3 checks passed.'
