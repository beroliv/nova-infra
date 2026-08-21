#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE="$ROOT_DIR/lib/phase6.sh"

grep -Fq 'reverse_proxy 192.168.0.195:3000' "$PHASE"
grep -Fq 'if cmp -s -- "$temporary_file" "$caddyfile"; then' "$PHASE"
grep -Fq 'cat "$temporary_file" > "$caddyfile"' "$PHASE"
grep -Fq 'docker exec caddy caddy validate' "$PHASE"
grep -Fq 'docker exec caddy caddy reload' "$PHASE"
grep -Fq 'docker exec caddy grep -Fq "$hostname" /etc/caddy/Caddyfile' "$PHASE"
if grep -Eq 'nova_phase6_(restore_caddy_ca|recreate_caddy|stop_caddy)|certificates/local|docker compose' "$PHASE"; then
  printf '%s\n' 'Phase 6 must only manage the Nova Caddy host block.' >&2
  exit 1
fi
if grep -Fq 'mv -f -- "$temporary_file" "$caddyfile"' "$PHASE"; then
  printf '%s\n' 'Phase 6 must preserve the bind-mounted Caddyfile inode.' >&2
  exit 1
fi

printf '%s\n' 'Phase 6 Caddy integration checks passed.'
