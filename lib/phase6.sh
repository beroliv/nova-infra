#!/usr/bin/env bash

# Phase 6 only: add Nova's local HTTPS hosts to the existing appliance Caddyfile.
# The Vaultwarden Appliance remains the sole owner of Caddy and its CA data.

readonly NOVA_PHASE6_BEGIN_MARKER="# BEGIN NOVA-INFRA HOSTS"
readonly NOVA_PHASE6_END_MARKER="# END NOVA-INFRA HOSTS"
readonly NOVA_PHASE6_CADDYFILE_RELATIVE_PATH="opt/vaultwarden/Caddyfile"
readonly NOVA_PHASE6_CADDY_DATA_RELATIVE_PATH="opt/vaultwarden/data/caddy/data"
readonly NOVA_PHASE6_CADDY_CA_MARKER_RELATIVE_PATH="opt/vaultwarden/data/caddy/.nova-infra-ca-restored"

nova_phase6_require_commands() {
  local command_name
  local missing=0

  for command_name in awk cat cmp cp dirname docker findmnt grep mkdir mktemp mv readlink rm rmdir systemctl chmod chown; do
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

nova_phase6_restore_caddy_ca() {
  local data_dir marker recovery_root recovery_real source_dir source_real
  local target_pki target_authority staging_file marker_file mounted_uuid file mode
  data_dir="$(nova_phase1_root_path "/${NOVA_PHASE6_CADDY_DATA_RELATIVE_PATH}")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE6_CADDY_CA_MARKER_RELATIVE_PATH}")"
  target_pki="${data_dir}/caddy/pki"
  target_authority="${target_pki}/authorities/local"
  if [[ -L "$data_dir" || ( -e "$data_dir" && ! -d "$data_dir" ) || -L "$marker" || ( -e "$marker" && ! -f "$marker" ) ]]; then
    nova_phase1_error "Caddy data or CA marker path is unsafe."
    return 1
  fi
  if [[ -f "$marker" ]]; then
    for file in root.crt root.key intermediate.crt intermediate.key; do
      [[ -f "${target_authority}/${file}" && ! -L "${target_authority}/${file}" ]] || {
        nova_phase1_error "Caddy CA marker exists but the complete authority is missing."
        return 1
      }
    done
    nova_phase1_ok "Existing restored Caddy local CA preserved."
    return 0
  fi

  nova_phase1_discover_recovery
  recovery_root="$NOVA_PHASE1_RECOVERY_ROOT"
  if [[ -z "$recovery_root" ]]; then
    nova_phase1_info "INFRA-RECOVERY is unavailable; preserving the existing Caddy CA."
    return 0
  fi
  source_dir="${recovery_root}/backup/caddy/pki/authorities/local"
  if [[ -L "$source_dir" || ! -d "$source_dir" ]]; then
    nova_phase1_error "INFRA-RECOVERY Caddy authority directory is missing or unsafe."
    nova_phase1_cleanup_recovery || true
    return 1
  fi
  recovery_real="$(readlink -f -- "$recovery_root")"
  source_real="$(readlink -f -- "$source_dir")"
  if [[ "$source_real" != "${recovery_real}/backup/caddy/pki/authorities/local" ]]; then
    nova_phase1_error "Caddy recovery authority resolves outside INFRA-RECOVERY."
    nova_phase1_cleanup_recovery || true
    return 1
  fi
  mounted_uuid="$(findmnt -rn -T "$source_real" -o UUID 2>/dev/null || true)"
  if [[ -n "$NOVA_PHASE1_RECOVERY_UUID" && "$mounted_uuid" != "$NOVA_PHASE1_RECOVERY_UUID" ]]; then
    nova_phase1_error "Caddy recovery authority is not on the validated recovery filesystem."
    nova_phase1_cleanup_recovery || true
    return 1
  fi
  for file in root.crt root.key intermediate.crt intermediate.key; do
    if [[ -L "${source_real}/${file}" || ! -f "${source_real}/${file}" ]]; then
      nova_phase1_error "INFRA-RECOVERY Caddy authority is incomplete."
      nova_phase1_cleanup_recovery || true
      return 1
    fi
  done

  systemctl stop caddy >/dev/null 2>&1 || docker stop caddy >/dev/null 2>&1 || true
  mkdir -p -- "${target_pki}/authorities"
  staging_file="$(mktemp -d "${target_authority}.candidate.XXXXXX")"
  for file in root.crt root.key intermediate.crt intermediate.key; do
    cp -- "${source_real}/${file}" "${staging_file}/${file}"
    mode=0644
    [[ "$file" == *.key ]] && mode=0600
    chmod "$mode" -- "${staging_file}/${file}"
    chown root:root -- "${staging_file}/${file}"
  done
  rm -f -- "${target_authority}/root.crt" "${target_authority}/root.key" \
    "${target_authority}/intermediate.crt" "${target_authority}/intermediate.key"
  if [[ -e "$target_authority" ]]; then
    rmdir -- "$target_authority"
  fi
  mv -- "$staging_file" "$target_authority"
  rm -rf -- "${target_pki}/certificates"
  mkdir -p -- "$(dirname -- "$marker")"
  marker_file="$(mktemp "${marker}.candidate.XXXXXX")"
  printf '%s\n' 'nova-infra Caddy local CA restored' > "$marker_file"
  chmod 0644 -- "$marker_file"
  chown root:root -- "$marker_file"
  mv -f -- "$marker_file" "$marker"
  if ! docker start caddy >/dev/null; then
    nova_phase1_error "Caddy could not be started after local CA restoration."
    nova_phase1_cleanup_recovery || true
    return 1
  fi
  nova_phase1_cleanup_recovery || return 1
  nova_phase1_ok "Complete Caddy local CA restored from INFRA-RECOVERY."
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
  chmod 0644 -- "$backup_file"
  chown root:root -- "$backup_file"
  mv -f -- "$temporary_file" "$caddyfile"

  if ! docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null; then
    mv -f -- "$backup_file" "$caddyfile"
    nova_phase1_error "The updated Caddyfile failed validation; the previous configuration was restored."
    return 1
  fi
  if ! docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null; then
    mv -f -- "$backup_file" "$caddyfile"
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || true
    nova_phase1_error "Caddy reload failed; the previous configuration was restored."
    return 1
  fi
  rm -f -- "$backup_file"
  nova_phase1_ok "Added Nova internal HTTPS hosts to the existing Caddy deployment."
}

nova_phase6_main() {
  nova_phase1_info "Phase 6 Nova internal Caddy hosts"
  nova_phase6_require_commands
  nova_phase6_require_appliance
  nova_phase6_restore_caddy_ca
  nova_phase6_install_caddy_hosts
  nova_phase1_ok "Vaultwarden Appliance Caddy and CA ownership remain unchanged."
}
