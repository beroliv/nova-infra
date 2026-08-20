#!/usr/bin/env bash

# Phase 7 only: deploy the official AdGuard Home image with host networking.

readonly NOVA_PHASE7_IMAGE="adguard/adguardhome:v0.107.78"
readonly NOVA_PHASE7_INSTALL_DIR_RELATIVE_PATH="opt/adguard"
readonly NOVA_PHASE7_CONF_DIR_RELATIVE_PATH="opt/adguard/conf"
readonly NOVA_PHASE7_WORK_DIR_RELATIVE_PATH="opt/adguard/work"
readonly NOVA_PHASE7_COMPOSE_RELATIVE_PATH="opt/adguard/compose.yml"
readonly NOVA_PHASE7_CONFIG_RELATIVE_PATH="opt/adguard/conf/AdGuardHome.yaml"
readonly NOVA_PHASE7_RECOVERY_MARKER_RELATIVE_PATH="opt/adguard/.nova-infra-recovery-restored"
readonly NOVA_PHASE7_CADDYFILE_RELATIVE_PATH="opt/vaultwarden/Caddyfile"
NOVA_PHASE7_CONFIG_CHANGED=0

nova_phase7_require_commands() {
  local command_name missing=0
  for command_name in chmod chown cmp cp docker findmnt grep mkdir mktemp mv readlink rm; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      nova_phase1_error "Required AdGuard command is missing: ${command_name}"
      missing=1
    fi
  done
  (( missing == 0 ))
}

nova_phase7_require_prerequisites() {
  local marker caddyfile
  marker="$(nova_phase1_root_path "/${NOVA_PHASE5_APPLIANCE_MARKER_RELATIVE_PATH}")"
  caddyfile="$(nova_phase1_root_path "/${NOVA_PHASE7_CADDYFILE_RELATIVE_PATH}")"
  if [[ ! -f "$marker" || -L "$marker" || ! -f "$caddyfile" || -L "$caddyfile" ]]; then
    nova_phase1_error "Phase 7 requires the installed Vaultwarden Appliance and Caddy configuration."
    return 1
  fi
  if ! grep -Fxq '# BEGIN NOVA-INFRA HOSTS' "$caddyfile"; then
    nova_phase1_error "Phase 7 requires the completed Nova Caddy host integration."
    return 1
  fi
}

nova_phase7_prepare_paths() {
  local install_dir conf_dir work_dir
  install_dir="$(nova_phase1_root_path "/${NOVA_PHASE7_INSTALL_DIR_RELATIVE_PATH}")"
  conf_dir="$(nova_phase1_root_path "/${NOVA_PHASE7_CONF_DIR_RELATIVE_PATH}")"
  work_dir="$(nova_phase1_root_path "/${NOVA_PHASE7_WORK_DIR_RELATIVE_PATH}")"
  for directory in "$install_dir" "$conf_dir" "$work_dir"; do
    if [[ -e "$directory" && ( ! -d "$directory" || -L "$directory" ) ]]; then
      nova_phase1_error "AdGuard path is not a safe directory: ${directory}"
      return 1
    fi
    mkdir -p -- "$directory"
    chmod 0755 -- "$directory"
    chown root:root -- "$directory"
  done
}

nova_phase7_restore_config() {
  local config marker recovery_root recovery_real source_config source_real \
    temporary_file marker_file mounted_uuid
  config="$(nova_phase1_root_path "/${NOVA_PHASE7_CONFIG_RELATIVE_PATH}")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE7_RECOVERY_MARKER_RELATIVE_PATH}")"
  if [[ -L "$config" || ( -e "$config" && ! -f "$config" ) || -L "$marker" || ( -e "$marker" && ! -f "$marker" ) ]]; then
    nova_phase1_error "AdGuard configuration or recovery marker is not a safe regular file."
    return 1
  fi
  if [[ -f "$marker" ]]; then
    [[ -f "$config" ]] || { nova_phase1_error "AdGuard recovery marker exists but configuration is missing."; return 1; }
    nova_phase1_ok "Existing recovered AdGuard configuration preserved."
    return 0
  fi
  if [[ -f "$config" ]]; then
    nova_phase1_error "An existing unmanaged AdGuard configuration will not be overwritten."
    return 1
  fi

  nova_phase1_discover_recovery
  recovery_root="$NOVA_PHASE1_RECOVERY_ROOT"
  if [[ -z "$recovery_root" ]]; then
    nova_phase1_error "INFRA-RECOVERY AdGuardHome.yaml is unavailable; refusing incomplete configuration."
    return 1
  fi
  source_config="${recovery_root}/backup/adguard/AdGuardHome.yaml"
  if [[ -L "$source_config" || ! -f "$source_config" ]]; then
    nova_phase1_error "INFRA-RECOVERY is missing a regular AdGuardHome.yaml."
    nova_phase1_cleanup_recovery || true
    return 1
  fi
  recovery_real="$(readlink -f -- "$recovery_root")"
  source_real="$(readlink -f -- "$source_config")"
  if [[ "$source_real" != "${recovery_real}/backup/adguard/AdGuardHome.yaml" ]]; then
    nova_phase1_error "AdGuard recovery configuration resolves outside INFRA-RECOVERY."
    nova_phase1_cleanup_recovery || true
    return 1
  fi
  mounted_uuid="$(findmnt -rn -T "$source_real" -o UUID 2>/dev/null || true)"
  if [[ -n "$NOVA_PHASE1_RECOVERY_UUID" && "$mounted_uuid" != "$NOVA_PHASE1_RECOVERY_UUID" ]]; then
    nova_phase1_error "AdGuard recovery configuration is not on the validated recovery filesystem."
    nova_phase1_cleanup_recovery || true
    return 1
  fi
  docker stop adguardhome >/dev/null 2>&1 || true
  temporary_file="$(mktemp "${config}.candidate.XXXXXX")"
  cp -- "$source_real" "$temporary_file"
  chmod 0640 -- "$temporary_file"
  chown root:root -- "$temporary_file"
  mv -f -- "$temporary_file" "$config"
  chmod 0640 -- "$config"
  chown root:root -- "$config"
  marker_file="$(mktemp "${marker}.candidate.XXXXXX")"
  printf '%s\n' 'nova-infra AdGuard recovery configuration restored' > "$marker_file"
  chmod 0644 -- "$marker_file"
  chown root:root -- "$marker_file"
  mv -f -- "$marker_file" "$marker"
  NOVA_PHASE7_CONFIG_CHANGED=1
  nova_phase1_cleanup_recovery || return 1
  nova_phase1_ok "AdGuard configuration restored from INFRA-RECOVERY without exposing its contents."
}

nova_phase7_write_compose() {
  local compose temporary_file
  compose="$(nova_phase1_root_path "/${NOVA_PHASE7_COMPOSE_RELATIVE_PATH}")"
  temporary_file="$(mktemp "${compose}.candidate.XXXXXX")"
  printf '%s\n' \
    'services:' \
    '  adguardhome:' \
    "    image: ${NOVA_PHASE7_IMAGE}" \
    '    container_name: adguardhome' \
    '    network_mode: host' \
    '    restart: unless-stopped' \
    '    volumes:' \
    '      - /opt/adguard/work:/opt/adguardhome/work' \
    '      - /opt/adguard/conf:/opt/adguardhome/conf' > "$temporary_file"
  chmod 0644 -- "$temporary_file"
  chown root:root -- "$temporary_file"
  if [[ -f "$compose" ]] && cmp -s -- "$temporary_file" "$compose"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$compose"
    NOVA_PHASE7_CONFIG_CHANGED=1
  fi
  chmod 0644 -- "$compose"
  chown root:root -- "$compose"
}

nova_phase7_deploy() {
  local install_dir compose
  install_dir="$(nova_phase1_root_path "/${NOVA_PHASE7_INSTALL_DIR_RELATIVE_PATH}")"
  compose="$(nova_phase1_root_path "/${NOVA_PHASE7_COMPOSE_RELATIVE_PATH}")"
  if ! docker compose --project-directory "$install_dir" -f "$compose" config --quiet; then
    nova_phase1_error "AdGuard Home Compose configuration is invalid."
    return 1
  fi
  nova_phase1_info "Starting the official AdGuard Home container with host networking."
  local -a up_args=(up -d)
  if (( NOVA_PHASE7_CONFIG_CHANGED == 1 )); then
    up_args+=(--force-recreate)
  fi
  if ! docker compose --project-directory "$install_dir" -f "$compose" "${up_args[@]}"; then
    nova_phase1_error "AdGuard Home container deployment failed."
    return 1
  fi
  nova_phase1_ok "AdGuard Home deployment requested; native Unbound and Caddy were not modified."
}

nova_phase7_main() {
  nova_phase1_info "Phase 7 AdGuard Home container"
  nova_phase7_require_commands
  nova_phase7_require_prerequisites
  nova_phase7_prepare_paths
  nova_phase7_restore_config
  nova_phase7_write_compose
  nova_phase7_deploy
}
