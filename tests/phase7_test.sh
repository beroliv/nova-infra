#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE="$ROOT_DIR/lib/phase7.sh"

grep -Fq 'NOVA_PHASE7_RECOVERY_MARKER_RELATIVE_PATH="opt/adguard/.nova-infra-recovery-restored"' "$PHASE"
grep -Fq 'backup/adguard/AdGuardHome.yaml' "$PHASE"
grep -Fq 'readlink -f -- "$source_config"' "$PHASE"
grep -Fq 'findmnt -rn -T "$source_real" -o UUID' "$PHASE"
grep -Fq 'docker stop adguardhome' "$PHASE"
grep -Fq 'nova_phase1_cleanup_recovery || return 1' "$PHASE"
if grep -Fq 'ADGUARD_PASSWORD_HASH' "$PHASE"; then
  printf '%s\n' 'Phase 7 must not consume the removed AdGuard secret.' >&2
  exit 1
fi
if grep -Fq 'schema_version: 34' "$PHASE"; then
  printf '%s\n' 'Phase 7 must not synthesize an AdGuard configuration.' >&2
  exit 1
fi

printf '%s\n' 'Phase 7 recovery checks passed.'
