#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE="$ROOT_DIR/lib/phase6.sh"

grep -Fq 'reverse_proxy 192.168.0.195:3000' "$PHASE"
grep -Fq 'backup/caddy/pki/authorities/local' "$PHASE"
grep -Fq 'root.crt root.key intermediate.crt intermediate.key' "$PHASE"
grep -Fq 'nova_phase6_restore_caddy_ca' "$PHASE"
grep -Fq 'rm -rf -- "${target_pki}/certificates"' "$PHASE"
grep -Fq 'rmdir -- "$target_authority"' "$PHASE"
grep -Fq 'nova-infra-ca-restored' "$PHASE"
if grep -Fq 'root.crt" "$source_real/root.crt"' "$PHASE"; then
  printf '%s\n' 'Phase 6 must copy the complete authority through the staged restore.' >&2
  exit 1
fi

printf '%s\n' 'Phase 6 Caddy recovery checks passed.'
