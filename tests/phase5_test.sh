#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE="$ROOT_DIR/lib/phase5.sh"

grep -Fq 'NOVA_PHASE5_CADDY_RECOVERY_RELATIVE_PATH="backup/caddy/pki/authorities/local"' "$PHASE"
grep -Fq 'NOVA_PHASE5_CADDY_AUTHORITY_RELATIVE_PATH="opt/vaultwarden/data/caddy/data/caddy/pki/authorities/local"' "$PHASE"
grep -Fq 'Complete Caddy local CA preseeded before the Vaultwarden Appliance starts.' "$PHASE"
grep -Fq 'NOVA_PHASE5_APPLIANCE_STATE="preseeded"' "$PHASE"
grep -Fq 'Only the validated Caddy CA preseed is present; continuing fresh Appliance installation.' "$PHASE"
grep -Fq 'nova_phase5_is_safe_caddy_preseed' "$PHASE"
grep -Fq 'find "$appliance_dir" -mindepth 1 -print' "$PHASE"
grep -Fq 'mv -- "$staging_file" "$authority"' "$PHASE"
grep -Fq 'NOVA_PHASE5_APPLIANCE_OVERRIDE_COMPOSE_RELATIVE_PATH="opt/vaultwarden/docker-compose.override.yml"' "$PHASE"
grep -Fq 'NOVA_PHASE5_APPLIANCE_VWCTL_COMPOSE_RELATIVE_PATH="opt/vaultwarden/docker-compose.vwctl.yml"' "$PHASE"
grep -Fq '&& -f "$override_compose_file" && ! -L "$override_compose_file"' "$PHASE"
grep -Fq '&& -f "$vwctl_compose_file" && ! -L "$vwctl_compose_file"' "$PHASE"
if ! awk '
  /^[[:space:]]+nova_phase5_preseed_caddy_ca$/ { preseed=NR }
  /^[[:space:]]+nova_phase5_install_appliance$/ { install=NR }
  END { exit !(preseed && install && preseed < install) }
' "$PHASE"; then
  printf '%s\n' 'Phase 5 must preseed the Caddy CA before appliance installation.' >&2
  exit 1
fi
if grep -Fq 'certificates/local' "$PHASE"; then
  printf '%s\n' 'Phase 5 must not delete post-start Caddy leaf certificates.' >&2
  exit 1
fi

source "$PHASE"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/data/caddy/data/caddy/pki/authorities/local"
for name in root.crt root.key intermediate.crt intermediate.key; do
  printf 'fixture\n' > "$fixture/data/caddy/data/caddy/pki/authorities/local/$name"
done
if ! nova_phase5_is_safe_caddy_preseed "$fixture"; then
  printf '%s\n' 'A complete Caddy preseed fixture must be accepted.' >&2
  exit 1
fi
printf 'unexpected\n' > "$fixture/unexpected.txt"
if nova_phase5_is_safe_caddy_preseed "$fixture"; then
  printf '%s\n' 'Unexpected unmarked preseed content must be rejected.' >&2
  exit 1
fi

printf '%s\n' 'Phase 5 Caddy preseed checks passed.'
