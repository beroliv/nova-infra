#!/usr/bin/env bash

# Phase 5 only: orchestrate the existing Vaultwarden Appliance project.
# Vaultwarden, Caddy, backups, and restore remain owned by that project.

readonly NOVA_PHASE5_APPLIANCE_INSTALLER_URL="https://raw.githubusercontent.com/beroliv/vaultwarden-appliance/main/bootstrap.sh"
readonly NOVA_PHASE5_APPLIANCE_DIR_RELATIVE_PATH="opt/vaultwarden"
readonly NOVA_PHASE5_APPLIANCE_MARKER_RELATIVE_PATH="opt/vaultwarden/.vaultwarden-appliance"
readonly NOVA_PHASE5_APPLIANCE_COMPOSE_RELATIVE_PATH="opt/vaultwarden/docker-compose.yml"
readonly NOVA_PHASE5_APPLIANCE_CADDYFILE_RELATIVE_PATH="opt/vaultwarden/Caddyfile"
readonly NOVA_PHASE5_APPLIANCE_DATA_RELATIVE_PATH="opt/vaultwarden/data"

nova_phase5_require_commands() {
  local command_name
  local missing=0

  for command_name in curl docker grep; do
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
  local appliance_dir marker compose_file caddyfile data_dir

  appliance_dir="$(nova_phase1_root_path "/${NOVA_PHASE5_APPLIANCE_DIR_RELATIVE_PATH}")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE5_APPLIANCE_MARKER_RELATIVE_PATH}")"
  compose_file="$(nova_phase1_root_path "/${NOVA_PHASE5_APPLIANCE_COMPOSE_RELATIVE_PATH}")"
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
    && -f "$caddyfile" && ! -L "$caddyfile" \
    && -d "$data_dir" && ! -L "$data_dir" ]]; then
    NOVA_PHASE5_APPLIANCE_STATE="existing"
    nova_phase1_ok "Existing valid Vaultwarden Appliance installation detected."
    return 0
  fi
  nova_phase1_error "The Vaultwarden Appliance path exists without a valid complete installation."
  return 1
}

nova_phase5_install_appliance() {
  nova_phase1_info "Starting the authoritative Vaultwarden Appliance installer."
  nova_phase1_info "The appliance owns Vaultwarden, Caddy, backups, and restore; nova-infra will not duplicate them."
  if ! curl -fsSL --proto '=https' --tlsv1.2 "$NOVA_PHASE5_APPLIANCE_INSTALLER_URL" | bash; then
    nova_phase1_error "The Vaultwarden Appliance installer failed."
    return 1
  fi
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
    nova_phase5_install_appliance
    nova_phase5_check_existing_installation
  else
    nova_phase1_info "Existing appliance-managed files and Caddy configuration will not be overwritten."
  fi
  nova_phase5_check_containers
  nova_phase1_ok "Vaultwarden data restore remains the existing appliance's responsibility."
}
