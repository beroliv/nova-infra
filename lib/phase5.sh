#!/usr/bin/env bash

# Phase 5 only: orchestrate the existing Vaultwarden Appliance project.
# Vaultwarden, Caddy, backups, and restore remain owned by that project.

readonly NOVA_PHASE5_APPLIANCE_INSTALLER_URL="https://raw.githubusercontent.com/beroliv/vaultwarden-appliance/main/bootstrap.sh"
readonly NOVA_PHASE5_APPLIANCE_DIR_RELATIVE_PATH="opt/vaultwarden"
readonly NOVA_PHASE5_APPLIANCE_MARKER_RELATIVE_PATH="opt/vaultwarden/.vaultwarden-appliance"
readonly NOVA_PHASE5_APPLIANCE_COMPOSE_RELATIVE_PATH="opt/vaultwarden/docker-compose.yml"
readonly NOVA_PHASE5_APPLIANCE_OVERRIDE_COMPOSE_RELATIVE_PATH="opt/vaultwarden/docker-compose.override.yml"
readonly NOVA_PHASE5_APPLIANCE_VWCTL_COMPOSE_RELATIVE_PATH="opt/vaultwarden/docker-compose.vwctl.yml"
readonly NOVA_PHASE5_APPLIANCE_CADDYFILE_RELATIVE_PATH="opt/vaultwarden/Caddyfile"
readonly NOVA_PHASE5_APPLIANCE_DATA_RELATIVE_PATH="opt/vaultwarden/data"
readonly NOVA_PHASE5_CADDY_DATA_RELATIVE_PATH="opt/vaultwarden/data/caddy/data"
readonly NOVA_PHASE5_CADDY_AUTHORITY_RELATIVE_PATH="opt/vaultwarden/data/caddy/data/caddy/pki/authorities/local"
readonly NOVA_PHASE5_CADDY_RECOVERY_RELATIVE_PATH="backup/caddy/pki/authorities/local"

nova_phase5_require_commands() {
  local command_name
  local missing=0

  for command_name in chmod chown cp curl dirname docker find findmnt grep mkdir mktemp mv readlink; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      nova_phase1_error "Required Vaultwarden Appliance command is missing: ${command_name}"
      missing=1
    fi
  done
  (( missing == 0 ))
}

nova_phase5_require_phase4c() {
  local marker
  marker="$(nova_phase1_root_path "/${NOVA_PHASE4C_MARKER_RELATIVE_PATH}")"
  if [[ ! -f "$marker" || -L "$marker" ]] || ! grep -Fxq 'phase=4c' "$marker"; then
    nova_phase1_error "Phase 5 requires a successfully completed Phase 4c marker."
    return 1
  fi
  nova_phase1_ok "Phase 4c is complete."
}

nova_phase5_check_existing_installation() {
  local appliance_dir marker compose_file override_compose_file vwctl_compose_file caddyfile data_dir

  appliance_dir="$(nova_phase1_root_path "/${NOVA_PHASE5_APPLIANCE_DIR_RELATIVE_PATH}")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE5_APPLIANCE_MARKER_RELATIVE_PATH}")"
  compose_file="$(nova_phase1_root_path "/${NOVA_PHASE5_APPLIANCE_COMPOSE_RELATIVE_PATH}")"
  override_compose_file="$(nova_phase1_root_path "/${NOVA_PHASE5_APPLIANCE_OVERRIDE_COMPOSE_RELATIVE_PATH}")"
  vwctl_compose_file="$(nova_phase1_root_path "/${NOVA_PHASE5_APPLIANCE_VWCTL_COMPOSE_RELATIVE_PATH}")"
  caddyfile="$(nova_phase1_root_path "/${NOVA_PHASE5_APPLIANCE_CADDYFILE_RELATIVE_PATH}")"
  data_dir="$(nova_phase1_root_path "/${NOVA_PHASE5_APPLIANCE_DATA_RELATIVE_PATH}")"

  if [[ ! -e "$appliance_dir" ]]; then
    NOVA_PHASE5_APPLIANCE_STATE="absent"
    nova_phase1_info "No Vaultwarden Appliance installation was detected."
    return 0
  fi
  if [[ ! -d "$appliance_dir" || -L "$appliance_dir" ]]; then
    nova_phase1_error "The Vaultwarden Appliance path exists but is not a safe directory."
    return 1
  fi
  if [[ -f "$marker" && ! -L "$marker" \
    && -f "$compose_file" && ! -L "$compose_file" \
    && -f "$override_compose_file" && ! -L "$override_compose_file" \
    && -f "$vwctl_compose_file" && ! -L "$vwctl_compose_file" \
    && -f "$caddyfile" && ! -L "$caddyfile" \
    && -d "$data_dir" && ! -L "$data_dir" ]]; then
    NOVA_PHASE5_APPLIANCE_STATE="existing"
    nova_phase1_ok "Existing valid Vaultwarden Appliance installation detected."
    return 0
  fi
  if nova_phase5_is_safe_caddy_preseed "$appliance_dir"; then
    NOVA_PHASE5_APPLIANCE_STATE="preseeded"
    nova_phase1_ok "Only the validated Caddy CA preseed is present; continuing fresh Appliance installation."
    return 0
  fi
  nova_phase1_error "The Vaultwarden Appliance path exists without a valid complete installation."
  return 1
}

nova_phase5_is_safe_caddy_preseed() {
  local appliance_dir="$1"
  local authority="${appliance_dir}/data/caddy/data/caddy/pki/authorities/local"
  local path expected allowed
  local -a expected_dirs=(
    "$appliance_dir/data"
    "$appliance_dir/data/caddy"
    "$appliance_dir/data/caddy/data"
    "$appliance_dir/data/caddy/data/caddy"
    "$appliance_dir/data/caddy/data/caddy/pki"
    "$appliance_dir/data/caddy/data/caddy/pki/authorities"
    "$authority"
  )
  local -a expected_files=(
    "$authority/root.crt"
    "$authority/root.key"
    "$authority/intermediate.crt"
    "$authority/intermediate.key"
  )
  for path in "${expected_dirs[@]}"; do
    [[ -d "$path" && ! -L "$path" ]] || return 1
  done
  for path in "${expected_files[@]}"; do
    [[ -f "$path" && ! -L "$path" ]] || return 1
  done
  while IFS= read -r path; do
    allowed=0
    for expected in "${expected_dirs[@]}" "${expected_files[@]}"; do
      if [[ "$path" == "$expected" ]]; then
        allowed=1
        break
      fi
    done
    (( allowed == 1 )) || return 1
  done < <(find "$appliance_dir" -mindepth 1 -print)
}

nova_phase5_install_appliance() {
  nova_phase1_info "Starting the authoritative Vaultwarden Appliance installer."
  nova_phase1_info "The appliance owns Vaultwarden, Caddy, backups, and restore; nova-infra will not duplicate them."
  if ! curl -fsSL --proto '=https' --tlsv1.2 "$NOVA_PHASE5_APPLIANCE_INSTALLER_URL" | bash; then
    nova_phase1_error "The Vaultwarden Appliance installer failed."
    return 1
  fi
}

nova_phase5_preseed_caddy_ca() {
  local data_dir caddy_root authority recovery_root recovery_real source_dir source_real
  local parent staging_file mounted_uuid file mode
  data_dir="$(nova_phase1_root_path "/${NOVA_PHASE5_CADDY_DATA_RELATIVE_PATH}")"
  caddy_root="$(dirname -- "$data_dir")"
  authority="$(nova_phase1_root_path "/${NOVA_PHASE5_CADDY_AUTHORITY_RELATIVE_PATH}")"
  for parent in "$caddy_root" "$data_dir" "${data_dir}/caddy" \
    "${data_dir}/caddy/pki" "${data_dir}/caddy/pki/authorities"; do
    if [[ -L "$parent" || ( -e "$parent" && ! -d "$parent" ) ]]; then
      nova_phase1_error "Caddy preseed path is unsafe: ${parent}"
      return 1
    fi
  done

  nova_phase1_discover_recovery
  recovery_root="$NOVA_PHASE1_RECOVERY_ROOT"
  if [[ -z "$recovery_root" ]]; then
    nova_phase1_info "INFRA-RECOVERY is unavailable; Caddy will create a new CA."
    return 0
  fi
  source_dir="${recovery_root}/${NOVA_PHASE5_CADDY_RECOVERY_RELATIVE_PATH}"
  if [[ ! -e "$source_dir" && ! -L "$source_dir" ]]; then
    nova_phase1_cleanup_recovery || return 1
    nova_phase1_info "No Caddy CA backup found on INFRA-RECOVERY; Caddy will create a new CA."
    return 0
  fi
  if [[ -L "$source_dir" || ! -d "$source_dir" ]]; then
    nova_phase1_error "INFRA-RECOVERY Caddy authority directory is missing or unsafe."
    nova_phase1_cleanup_recovery || true
    return 1
  fi
  recovery_real="$(readlink -f -- "$recovery_root")"
  source_real="$(readlink -f -- "$source_dir")"
  if [[ "$source_real" != "${recovery_real}/${NOVA_PHASE5_CADDY_RECOVERY_RELATIVE_PATH}" ]]; then
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
  mkdir -p -- "$(dirname -- "$authority")"
  if [[ -e "$authority" || -L "$authority" ]]; then
    nova_phase1_error "Caddy authority destination already exists during fresh preseed."
    nova_phase1_cleanup_recovery || true
    return 1
  fi
  staging_file="$(mktemp -d "${authority}.candidate.XXXXXX")"
  for file in root.crt root.key intermediate.crt intermediate.key; do
    cp -- "${source_real}/${file}" "${staging_file}/${file}"
    mode=0644
    [[ "$file" == *.key ]] && mode=0600
    chmod "$mode" -- "${staging_file}/${file}"
    chown root:root -- "${staging_file}/${file}"
  done
  mv -- "$staging_file" "$authority"
  nova_phase1_cleanup_recovery || return 1
  nova_phase1_ok "Complete Caddy local CA preseeded before the Vaultwarden Appliance starts."
}

nova_phase5_check_containers() {
  local container running
  for container in vaultwarden caddy; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
      nova_phase1_error "Vaultwarden Appliance container is missing: ${container}"
      return 1
    fi
    running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)"
    if [[ "$running" != "true" ]]; then
      nova_phase1_error "Vaultwarden Appliance container is not running: ${container}"
      return 1
    fi
  done
  nova_phase1_ok "Vaultwarden Appliance containers vaultwarden and caddy exist and are running."
}

nova_phase5_main() {
  nova_phase1_info "Phase 5 Vaultwarden Appliance integration"
  nova_phase5_require_commands
  nova_phase5_require_phase4c
  nova_phase5_check_existing_installation
  if [[ "$NOVA_PHASE5_APPLIANCE_STATE" == "absent" ]]; then
    nova_phase5_preseed_caddy_ca
    nova_phase5_install_appliance
    nova_phase5_check_existing_installation
  elif [[ "$NOVA_PHASE5_APPLIANCE_STATE" == "preseeded" ]]; then
    nova_phase5_install_appliance
    nova_phase5_check_existing_installation
  else
    nova_phase1_info "Existing appliance-managed files and Caddy configuration will not be overwritten."
  fi
  nova_phase5_check_containers
  nova_phase1_ok "Vaultwarden data restore remains the existing appliance's responsibility."
}
