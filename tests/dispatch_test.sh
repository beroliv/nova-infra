#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE11_COUNT="$(grep -Ec '^[[:space:]]+nova_phase11_main$' "$ROOT_DIR/install.sh")"
if [[ "$PHASE11_COUNT" != "1" ]]; then
  printf '%s\n' "Expected exactly one Phase 11 dispatch, found ${PHASE11_COUNT}." >&2
  exit 1
fi

printf '%s\n' 'Installer dispatch checks passed.'
