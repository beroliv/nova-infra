#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE="$ROOT_DIR/lib/phase8.sh"

grep -Fq 'NOVA_PHASE8_LOCAL_RELATIVE_PATH="home/admin/.local"' "$PHASE"
grep -Fq 'NOVA_PHASE8_STATE_PARENT_RELATIVE_PATH="home/admin/.local/state"' "$PHASE"
grep -Fq 'NOVA_PHASE8_STATE_RELATIVE_PATH="home/admin/.local/state/syncthing"' "$PHASE"
grep -Fq 'chown "${NOVA_PHASE8_USER}:${NOVA_PHASE8_USER}" -- "$directory"' "$PHASE"
grep -Fq 'chmod 0700 -- "$directory"' "$PHASE"
grep -Fq 'nova_phase8_prepare_state_directories' "$PHASE"
if grep -Eq 'chown[[:space:]]+-R[^\n]*(/home/admin|NOVA_PHASE8)' "$PHASE"; then
  printf '%s\n' 'Phase 8 must not recursively chown the admin home.' >&2
  exit 1
fi

printf '%s\n' 'Phase 8 ownership checks passed.'
