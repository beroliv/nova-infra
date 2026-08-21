#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE="$ROOT_DIR/lib/phase6.sh"

grep -Fq 'reverse_proxy 192.168.0.195:3000' "$PHASE"
grep -Fq 'NOVA_PHASE6_CADDY_RECOVERY_RELATIVE_PATH="backup/caddy/pki/authorities/local"' "$PHASE"
grep -Fq 'NOVA_PHASE6_CADDY_AUTHORITY_RELATIVE_PATH="caddy/pki/authorities/local"' "$PHASE"
grep -Fq 'No Caddy CA backup found on INFRA-RECOVERY; keeping current Caddy CA.' "$PHASE"
grep -Fq 'if [[ ! -e "$source_dir" && ! -L "$source_dir" ]]; then' "$PHASE"
grep -Fq 'root.crt root.key intermediate.crt intermediate.key' "$PHASE"
grep -Fq 'nova_phase6_restore_caddy_ca' "$PHASE"
grep -Fq 'up -d --force-recreate caddy' "$PHASE"
grep -Fq 'docker compose -f "$compose_file" up -d --force-recreate caddy' "$PHASE"
if grep -Fq 'docker compose --project-directory' "$PHASE"; then
  printf '%s\n' 'Phase 6 must not depend on the nova-infra Compose project context.' >&2
  exit 1
fi
grep -Fq 'if cmp -s -- "$temporary_file" "$caddyfile"; then' "$PHASE"
grep -Fq 'docker exec caddy grep -Fq "$hostname" /etc/caddy/Caddyfile' "$PHASE"
grep -Fq 'NOVA_PHASE6_BEGIN_MARKER' "$PHASE"
grep -Fq 'target_leaf_dir="${data_dir}/caddy/certificates/local"' "$PHASE"
grep -Fq 'rm -rf -- "$target_leaf_dir"' "$PHASE"
grep -Fq 'rmdir -- "$target_authority"' "$PHASE"
grep -Fq 'nova-infra-ca-restored' "$PHASE"
if grep -Fq 'root.crt" "$source_real/root.crt"' "$PHASE"; then
  printf '%s\n' 'Phase 6 must copy the complete authority through the staged restore.' >&2
  exit 1
fi

printf '%s\n' 'Phase 6 Caddy recovery checks passed.'
