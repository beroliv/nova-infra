#!/usr/bin/env bash

# Phase 6 only: add Nova's local HTTPS hosts to the existing appliance Caddyfile.
# The Vaultwarden Appliance remains the sole owner of Caddy and its CA data.

readonly NOVA_PHASE6_BEGIN_MARKER="# BEGIN NOVA-INFRA HOSTS"
readonly NOVA_PHASE6_END_MARKER="# END NOVA-INFRA HOSTS"
readonly NOVA_PHASE6_CADDYFILE_RELATIVE_PATH="opt/vaultwarden/Caddyfile"

nova_phase6_require_commands() {
  local command_name
  local missing=0

  for command_name in awk cat cmp cp docker grep mktemp mv rm chmod chown; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      nova_phase1_error "Required Nova Caddy command is missing: ${command_name}"
      missing=1
    fi
  done
  (( missing == 0 ))
}

nova_phase6_require_appliance() {
  local marker compose_file caddyfile

  marker="$(nova_phase1_root_path "/${NOVA_PHASE5_APPLIANCE_MARKER_RELATIVE_PATH}")"
  compose_file="$(nova_phase1_root_path "/${NOVA_PHASE5_APPLIANCE_COMPOSE_RELATIVE_PATH}")"
  caddyfile="$(nova_phase1_root_path "/${NOVA_PHASE6_CADDYFILE_RELATIVE_PATH}")"
  if [[ ! -f "$marker" || -L "$marker" || ! -f "$compose_file" || -L "$compose_file" \
    || ! -f "$caddyfile" || -L "$caddyfile" ]]; then
    nova_phase1_error "Phase 6 requires a valid installed Vaultwarden Appliance Caddyfile."
    return 1
  fi
  if ! docker inspect caddy >/dev/null 2>&1; then
    nova_phase1_error "Phase 6 requires the appliance-managed caddy container."
    return 1
  fi
}

nova_phase6_host_block() {
  cat <<'EOF'
# BEGIN NOVA-INFRA HOSTS
wg-easy.lan {
    tls internal
    reverse_proxy 192.168.0.195:51821
}

adguard-nova.lan {
    tls internal
    reverse_proxy 192.168.0.195:3000
}

adguard-arc.lan {
    tls internal
    reverse_proxy 192.168.0.193:80
}

ds3.lan {
    tls internal
    reverse_proxy 192.168.0.100:5000
}

syncthing-ds3.lan {
    tls internal
    reverse_proxy 192.168.0.100:8384
}

syncthing-nova.lan {
    tls internal
    reverse_proxy 192.168.0.195:8384
}
# END NOVA-INFRA HOSTS
EOF
}

nova_phase6_install_caddy_hosts() {
  local caddyfile temporary_file backup_file
  local begin_count end_count

  caddyfile="$(nova_phase1_root_path "/${NOVA_PHASE6_CADDYFILE_RELATIVE_PATH}")"
  begin_count="$(grep -Fc "$NOVA_PHASE6_BEGIN_MARKER" "$caddyfile" || true)"
  end_count="$(grep -Fc "$NOVA_PHASE6_END_MARKER" "$caddyfile" || true)"
  if [[ "$begin_count" != "$end_count" || "$begin_count" != "0" && "$begin_count" != "1" ]]; then
    nova_phase1_error "Existing Nova Caddy host markers are malformed or duplicated."
    return 1
  fi

  temporary_file="$(mktemp "${caddyfile}.nova.XXXXXX")"
  if ! awk -v begin="$NOVA_PHASE6_BEGIN_MARKER" -v end="$NOVA_PHASE6_END_MARKER" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$caddyfile" > "$temporary_file"; then
    rm -f -- "$temporary_file"
    nova_phase1_error "Could not prepare the existing Caddyfile for Nova hosts."
    return 1
  fi
  printf '\n' >> "$temporary_file"
  nova_phase6_host_block >> "$temporary_file"
  chmod 0644 -- "$temporary_file"
  chown root:root -- "$temporary_file"
  if cmp -s -- "$temporary_file" "$caddyfile"; then
    rm -f -- "$temporary_file"
    nova_phase1_ok "Nova Caddy hosts are already present and unchanged."
    return 0
  fi

  backup_file="$(mktemp "${caddyfile}.nova-backup.XXXXXX")"
  cp -- "$caddyfile" "$backup_file"
  if ! cat "$temporary_file" > "$caddyfile"; then
    cat "$backup_file" > "$caddyfile" || true
    rm -f -- "$temporary_file" "$backup_file"
    nova_phase1_error "Could not update the existing Caddyfile in place."
    return 1
  fi
  rm -f -- "$temporary_file"
  if ! docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null; then
    cat "$backup_file" > "$caddyfile"
    rm -f -- "$backup_file"
    nova_phase1_error "The updated Caddy configuration failed validation; the previous configuration was restored."
    return 1
  fi
  if ! docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null; then
    cat "$backup_file" > "$caddyfile"
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || true
    rm -f -- "$backup_file"
    nova_phase1_error "Caddy reload failed; the previous configuration was restored."
    return 1
  fi
  for hostname in vault.lan wg-easy.lan adguard-nova.lan adguard-arc.lan \
    ds3.lan syncthing-ds3.lan syncthing-nova.lan; do
    if ! docker exec caddy grep -Fq "$hostname" /etc/caddy/Caddyfile; then
      cat "$backup_file" > "$caddyfile"
      docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || true
      rm -f -- "$backup_file"
      nova_phase1_error "The recreated Caddy container does not contain expected host ${hostname}."
      return 1
    fi
  done
  if ! docker exec caddy grep -Fq "$NOVA_PHASE6_BEGIN_MARKER" /etc/caddy/Caddyfile; then
    cat "$backup_file" > "$caddyfile"
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || true
    rm -f -- "$backup_file"
    nova_phase1_error "The recreated Caddy container does not contain the Nova host marker."
    return 1
  fi
  rm -f -- "$backup_file"
  nova_phase1_ok "Added Nova internal HTTPS hosts to the existing Caddy deployment."
}

nova_phase6_main() {
  nova_phase1_info "Phase 6 Nova internal Caddy hosts"
  nova_phase6_require_commands
  nova_phase6_require_appliance
  nova_phase6_install_caddy_hosts
  nova_phase1_ok "Vaultwarden Appliance Caddy and CA ownership remain unchanged."
}
