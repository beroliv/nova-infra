#!/usr/bin/env bash

# Phase 7 only: deploy the official AdGuard Home image with host networking.

readonly NOVA_PHASE7_IMAGE="adguard/adguardhome:v0.107.78"
readonly NOVA_PHASE7_INSTALL_DIR_RELATIVE_PATH="opt/adguard"
readonly NOVA_PHASE7_CONF_DIR_RELATIVE_PATH="opt/adguard/conf"
readonly NOVA_PHASE7_WORK_DIR_RELATIVE_PATH="opt/adguard/work"
readonly NOVA_PHASE7_COMPOSE_RELATIVE_PATH="opt/adguard/compose.yml"
readonly NOVA_PHASE7_CONFIG_RELATIVE_PATH="opt/adguard/conf/AdGuardHome.yaml"
readonly NOVA_PHASE7_MARKER_RELATIVE_PATH="opt/adguard/.nova-infra-managed"
readonly NOVA_PHASE7_CADDYFILE_RELATIVE_PATH="opt/vaultwarden/Caddyfile"
NOVA_PHASE7_CONFIG_CHANGED=0

nova_phase7_require_commands() {
  local command_name missing=0
  for command_name in chmod chown cmp cp docker grep mkdir mktemp mv rm; do
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

nova_phase7_read_password_hash() {
  local result_name="$1"
  local secrets value
  secrets="$(nova_phase1_root_path "/${NOVA_PHASE1_LOCAL_SECRET_RELATIVE_PATH}")"
  value="$(nova_phase1_read_assignment "$secrets" ADGUARD_PASSWORD_HASH || true)"
  if [[ -z "$value" || "$value" == CHANGE_ME_* ]]; then
    nova_phase1_error "ADGUARD_PASSWORD_HASH is unresolved; AdGuard Home was not started."
    return 1
  fi
  printf -v "$result_name" '%s' "$value"
}

nova_phase7_write_config() {
  local password_hash="$1"
  local config marker temporary_file marker_file
  config="$(nova_phase1_root_path "/${NOVA_PHASE7_CONFIG_RELATIVE_PATH}")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE7_MARKER_RELATIVE_PATH}")"
  if [[ -e "$config" || -L "$config" ]] && [[ ! -f "$config" || -L "$config" ]]; then
    nova_phase1_error "AdGuard configuration path is not a safe regular file."
    return 1
  fi
  if [[ -f "$config" && ! -f "$marker" ]]; then
    nova_phase1_error "An existing unmanaged AdGuard configuration will not be overwritten."
    return 1
  fi
  temporary_file="$(mktemp "${config}.candidate.XXXXXX")"
  {
    printf '%s\n' '# nova-infra-managed AdGuard Home configuration'
    printf '%s\n' 'schema_version: 34'
    printf '%s\n' 'http:' '  address: 0.0.0.0:80'
    printf '%s\n' 'users:' '  - name: admin'
    printf '    password: %s\n' "$password_hash"
    printf '%s\n' \
      'dns:' \
      '  bind_hosts:' \
      '    - 0.0.0.0' \
      '  port: 53' \
      '  protection_enabled: true' \
      '  filtering_enabled: true' \
      '  refuse_any: true' \
      '  cache_enabled: false' \
      '  cache_size: 0' \
      '  enable_dnssec: false' \
      '  upstream_dns:' \
      '    - 127.0.0.1:5335' \
      '    - 192.168.0.193:5335' \
      '  upstream_mode: parallel' \
      '  fallback_dns: []' \
      '  bootstrap_dns:'
    printf '%s\n' \
      '    - 9.9.9.10' \
      '    - 149.112.112.10'
    printf '%s\n' \
      '  rewrites:' \
      '    - domain: arc.lan' \
      '      answer: 192.168.0.193' \
      '    - domain: ds3.lan' \
      '      answer: 192.168.0.195' \
      '    - domain: adguard-nova.lan' \
      '      answer: 192.168.0.195' \
      '    - domain: adguard-arc.lan' \
      '      answer: 192.168.0.195' \
      '    - domain: vault.lan' \
      '      answer: 192.168.0.195' \
      '    - domain: nova.lan' \
      '      answer: 192.168.0.195' \
      '    - domain: syncthing-nova.lan' \
      '      answer: 192.168.0.195' \
      '    - domain: syncthing-ds3.lan' \
      '      answer: 192.168.0.195' \
      '  filters:' \
      '    - enabled: true' \
      '      url: https://filters.adtidy.org/extension/ublock/filters/2.txt' \
      '      name: AdGuard DNS filter' \
      '      id: 1' \
      '    - enabled: true' \
      '      url: https://adaway.org/hosts.txt' \
      '      name: AdAway Default Blocklist' \
      '      id: 2' \
      '    - enabled: true' \
      '      url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt' \
      '      name: HaGeZi Normal Blocklist' \
      '      id: 3' \
      '    - enabled: true' \
      '      url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/whitelist-referral.txt' \
      '      name: HaGeZi Allowlist Referral' \
      '      id: 4' \
      '  user_rules: []' \
      'dhcp:' \
      '  enabled: false'
  } > "$temporary_file"
  chmod 0640 -- "$temporary_file"
  chown root:root -- "$temporary_file"
  if [[ -f "$config" ]] && cmp -s -- "$temporary_file" "$config"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$config"
    NOVA_PHASE7_CONFIG_CHANGED=1
  fi
  chmod 0640 -- "$config"
  chown root:root -- "$config"
  if [[ ! -f "$marker" ]]; then
    marker_file="$(mktemp "${marker}.candidate.XXXXXX")"
    printf '%s\n' 'nova-infra-managed AdGuard Home configuration' > "$marker_file"
    chmod 0644 -- "$marker_file"
    chown root:root -- "$marker_file"
    mv -f -- "$marker_file" "$marker"
  fi
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
  local password_hash=""
  nova_phase1_info "Phase 7 AdGuard Home container"
  nova_phase7_require_commands
  nova_phase7_require_prerequisites
  nova_phase7_prepare_paths
  nova_phase7_read_password_hash password_hash
  nova_phase7_write_config "$password_hash"
  nova_phase7_write_compose
  nova_phase7_deploy
}
