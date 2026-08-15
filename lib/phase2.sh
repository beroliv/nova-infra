#!/usr/bin/env bash

# Phase 2 only: APT metadata, full system upgrade, deterministic base packages,
# external repository preparation, and critical package-service safety.

readonly -a NOVA_PHASE2_BASE_PACKAGES=(
  "ca-certificates"
  "curl"
  "dnsutils"
  "git"
  "gnupg"
  "iproute2"
  "iptables"
  "iputils-ping"
  "jq"
  "nftables"
  "procps"
  "rsync"
  "sudo"
  "unattended-upgrades"
  "unbound"
  "unzip"
  "wireguard-tools"
  "xz-utils"
)
readonly -a NOVA_PHASE2_CRITICAL_UNITS=(
  "unbound.service"
  "unbound-resolvconf.service"
  "unbound-resolvconf.path"
  "nftables.service"
)
readonly NOVA_PHASE2_DOCKER_KEY_URL="https://download.docker.com/linux/debian/gpg"
readonly NOVA_PHASE2_DOCKER_REPOSITORY_URL="https://download.docker.com/linux/debian"
readonly NOVA_PHASE2_SYNCTHING_KEY_URL="https://syncthing.net/release-key.gpg"
readonly NOVA_PHASE2_SYNCTHING_REPOSITORY_URL="https://apt.syncthing.net/"
readonly NOVA_PHASE2_MARKER_RELATIVE_PATH="var/lib/nova-infra/phase2-complete"

NOVA_PHASE2_RESOLVER_FINGERPRINT=""
NOVA_PHASE2_PROTECTION_ACTIVE=0
NOVA_PHASE2_MARKER_EXISTED=0
declare -A NOVA_PHASE2_UNIT_ACTIVE_BEFORE=()
declare -A NOVA_PHASE2_UNIT_ENABLED_BEFORE=()

nova_phase2_is_test_mode() {
  [[ "${NOVA_PHASE2_TEST_MODE:-0}" == "1" ]]
}

nova_phase2_require_commands() {
  local command_name
  local missing=0
  local -a commands=(apt-get dpkg dpkg-query sha256sum systemctl)

  for command_name in "${commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      nova_phase1_error "Required Phase 2 command is missing: ${command_name}"
      missing=1
    fi
  done

  (( missing == 0 ))
}

nova_phase2_assert_safe_directory() {
  local directory="$1"
  local display_path="$2"
  local may_be_absent="${3:-0}"

  if [[ -e "$directory" || -L "$directory" ]]; then
    if [[ ! -d "$directory" || -L "$directory" ]]; then
      nova_phase1_error "Safe Phase 2 path validation failed: ${display_path} must be a real directory."
      return 1
    fi
  elif [[ "$may_be_absent" != "1" ]]; then
    nova_phase1_error "Safe Phase 2 path validation failed: ${display_path} is missing."
    return 1
  fi
}

nova_phase2_assert_safe_file_target() {
  local file="$1"
  local display_path="$2"

  if [[ -e "$file" || -L "$file" ]]; then
    if [[ ! -f "$file" || -L "$file" ]]; then
      nova_phase1_error "Safe Phase 2 path validation failed: ${display_path} must be a regular file."
      return 1
    fi
  fi
}

nova_phase2_check_safe_paths() {
  local apt_dir keyring_dir sources_dir var_lib_dir state_dir marker

  apt_dir="$(nova_phase1_root_path "/etc/apt")"
  keyring_dir="$(nova_phase1_root_path "/etc/apt/keyrings")"
  sources_dir="$(nova_phase1_root_path "/etc/apt/sources.list.d")"
  var_lib_dir="$(nova_phase1_root_path "/var/lib")"
  state_dir="$(nova_phase1_root_path "/var/lib/nova-infra")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE2_MARKER_RELATIVE_PATH}")"

  nova_phase2_assert_safe_directory "$apt_dir" "/etc/apt"
  nova_phase2_assert_safe_directory "$keyring_dir" "/etc/apt/keyrings" 1
  nova_phase2_assert_safe_directory "$sources_dir" "/etc/apt/sources.list.d"
  nova_phase2_assert_safe_directory "$var_lib_dir" "/var/lib"
  nova_phase2_assert_safe_directory "$state_dir" "/var/lib/nova-infra" 1

  nova_phase2_assert_safe_file_target "${keyring_dir}/docker.asc" "/etc/apt/keyrings/docker.asc"
  nova_phase2_assert_safe_file_target "${keyring_dir}/syncthing-archive-keyring.gpg" \
    "/etc/apt/keyrings/syncthing-archive-keyring.gpg"
  nova_phase2_assert_safe_file_target "${sources_dir}/docker.sources" \
    "/etc/apt/sources.list.d/docker.sources"
  nova_phase2_assert_safe_file_target "${sources_dir}/syncthing.list" \
    "/etc/apt/sources.list.d/syncthing.list"
  nova_phase2_assert_safe_file_target "$marker" "/var/lib/nova-infra/phase2-complete"

  nova_phase1_ok "Phase 2 APT, keyring, and state paths passed conservative safety checks."
}

nova_phase2_file_fingerprint() {
  local file="$1"
  local link_target hash

  if [[ -L "$file" ]]; then
    link_target="$(readlink -- "$file")"
    if [[ ! -e "$file" ]]; then
      printf 'broken-symlink:%s' "$link_target"
      return 0
    fi
    hash="$(sha256sum -- "$file")"
    printf 'symlink:%s:%s' "$link_target" "${hash%% *}"
  elif [[ -f "$file" ]]; then
    hash="$(sha256sum -- "$file")"
    printf 'file:%s' "${hash%% *}"
  elif [[ -e "$file" ]]; then
    printf 'other'
  else
    printf 'absent'
  fi
}

nova_phase2_check_repository_duplicates() {
  local sources_list sources_dir docker_target syncthing_target file line
  local -a source_files=()

  sources_list="$(nova_phase1_root_path "/etc/apt/sources.list")"
  sources_dir="$(nova_phase1_root_path "/etc/apt/sources.list.d")"
  docker_target="${sources_dir}/docker.sources"
  syncthing_target="${sources_dir}/syncthing.list"
  source_files+=("$sources_list")
  for file in "${sources_dir}"/*.list "${sources_dir}"/*.sources; do
    [[ -e "$file" || -L "$file" ]] || continue
    source_files+=("$file")
  done

  for file in "${source_files[@]}"; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      if [[ "$line" == *"${NOVA_PHASE2_DOCKER_REPOSITORY_URL}"* \
        && "$file" != "$docker_target" ]]; then
        nova_phase1_error "An unmanaged Docker APT source already exists at ${file}; refusing to add a duplicate."
        return 1
      fi
      if [[ "$line" == *"https://apt.syncthing.net"* \
        && "$file" != "$syncthing_target" ]]; then
        nova_phase1_error "An unmanaged Syncthing APT source already exists at ${file}; refusing to add a duplicate."
        return 1
      fi
    done < "$file"
  done
}

nova_phase2_marker_exists() {
  local marker
  marker="$(nova_phase1_root_path "/${NOVA_PHASE2_MARKER_RELATIVE_PATH}")"
  [[ -f "$marker" && ! -L "$marker" ]]
}

nova_phase2_read_unit_state() {
  local action="$1"
  local unit="$2"
  local state

  state="$(systemctl "$action" "$unit" 2>/dev/null || true)"
  printf '%s' "${state:-unknown}"
}

nova_phase2_prepare_service_safety() {
  local unit

  if nova_phase2_marker_exists; then
    NOVA_PHASE2_MARKER_EXISTED=1
    nova_phase1_info "Phase 2 was completed previously; preserving service states owned by later phases."
    return 0
  fi

  NOVA_PHASE2_MARKER_EXISTED=0
  for unit in "${NOVA_PHASE2_CRITICAL_UNITS[@]}"; do
    NOVA_PHASE2_UNIT_ACTIVE_BEFORE["$unit"]="$(nova_phase2_read_unit_state is-active "$unit")"
    NOVA_PHASE2_UNIT_ENABLED_BEFORE["$unit"]="$(nova_phase2_read_unit_state is-enabled "$unit")"
  done

  if [[ "${NOVA_PHASE2_UNIT_ACTIVE_BEFORE[unbound.service]}" == "active" ]]; then
    nova_phase1_error "Unbound is already active before initial Phase 2; refusing to alter an ambiguous DNS baseline."
    return 1
  fi

  NOVA_PHASE2_PROTECTION_ACTIVE=1
  for unit in "${NOVA_PHASE2_CRITICAL_UNITS[@]}"; do
    if ! systemctl mask --runtime "$unit" >/dev/null; then
      nova_phase1_error "Could not establish temporary package-start protection for ${unit}."
      return 1
    fi
  done
  nova_phase1_ok "Critical DNS and firewall package units are protected against first-install auto-start."
}

nova_phase2_unmask_protected_units() {
  local unit
  local failed=0

  if (( NOVA_PHASE2_PROTECTION_ACTIVE == 0 )); then
    return 0
  fi

  for unit in "${NOVA_PHASE2_CRITICAL_UNITS[@]}"; do
    if ! systemctl unmask --runtime "$unit" >/dev/null; then
      nova_phase1_error "Could not remove temporary package-start protection for ${unit}."
      failed=1
    fi
  done
  if (( failed == 0 )); then
    NOVA_PHASE2_PROTECTION_ACTIVE=0
  fi
  return "$failed"
}

nova_phase2_unit_exists() {
  systemctl cat "$1" >/dev/null 2>&1
}

nova_phase2_restore_nftables_baseline() {
  local active_before enabled_before active_after enabled_after

  nova_phase2_unit_exists "nftables.service" || return 0
  active_before="${NOVA_PHASE2_UNIT_ACTIVE_BEFORE[nftables.service]:-unknown}"
  enabled_before="${NOVA_PHASE2_UNIT_ENABLED_BEFORE[nftables.service]:-unknown}"
  active_after="$(nova_phase2_read_unit_state is-active nftables.service)"
  enabled_after="$(nova_phase2_read_unit_state is-enabled nftables.service)"

  if [[ "$active_before" == "active" && "$active_after" != "active" ]]; then
    systemctl start nftables.service >/dev/null
  elif [[ "$active_before" != "active" && "$active_after" == "active" ]]; then
    systemctl stop nftables.service >/dev/null
  fi

  if [[ "$enabled_before" == "enabled" && "$enabled_after" != "enabled" ]]; then
    systemctl enable nftables.service >/dev/null
  elif [[ "$enabled_before" != "enabled" && "$enabled_after" == "enabled" ]]; then
    systemctl disable nftables.service >/dev/null
  fi
}

nova_phase2_enforce_service_safety() {
  local unit

  if (( NOVA_PHASE2_MARKER_EXISTED == 1 )); then
    nova_phase1_ok "Service safety state from the completed initial Phase 2 remains under later-phase ownership."
    return 0
  fi

  nova_phase2_unmask_protected_units
  for unit in "unbound.service" "unbound-resolvconf.service" "unbound-resolvconf.path"; do
    if nova_phase2_unit_exists "$unit"; then
      systemctl disable --now "$unit" >/dev/null
    fi
  done
  nova_phase2_restore_nftables_baseline

  if systemctl is-active --quiet unbound.service; then
    nova_phase1_error "Unbound is active after Phase 2; refusing a premature DNS service takeover."
    return 1
  fi
  if [[ "$(nova_phase2_read_unit_state is-enabled unbound.service)" == "enabled" ]]; then
    nova_phase1_error "Unbound is enabled after Phase 2; dedicated DNS configuration must happen first."
    return 1
  fi

  nova_phase1_ok "Unbound remains inactive and disabled; nftables service state matches the pre-install baseline."
}

nova_phase2_best_effort_cleanup() {
  local original_status=$?
  local unit

  if (( NOVA_PHASE2_PROTECTION_ACTIVE == 1 )); then
    nova_phase2_unmask_protected_units || true
  fi
  if (( NOVA_PHASE2_MARKER_EXISTED == 0 )); then
    for unit in "unbound.service" "unbound-resolvconf.service" "unbound-resolvconf.path"; do
      if nova_phase2_unit_exists "$unit"; then
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
      fi
    done
    nova_phase2_restore_nftables_baseline >/dev/null 2>&1 || true
  fi

  return "$original_status"
}

nova_phase2_run_apt_update() {
  nova_phase1_info "Refreshing APT metadata."
  if ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
    apt-get update -qq --allow-releaseinfo-change -o Acquire::Retries=3; then
    nova_phase1_error "APT metadata update failed."
    return 1
  fi
  nova_phase1_ok "APT metadata update completed."
}

nova_phase2_run_full_upgrade() {
  nova_phase1_info "Running the non-interactive full system upgrade."
  if ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
    apt-get full-upgrade -y -qq -o Acquire::Retries=3 \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold; then
    nova_phase1_error "APT full-upgrade failed."
    return 1
  fi
  nova_phase1_ok "Full system upgrade completed."
}

nova_phase2_install_base_packages() {
  nova_phase1_info "Installing the deterministic Phase 2 base package set."
  if ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
    apt-get install -y -qq -o Acquire::Retries=3 \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
      "${NOVA_PHASE2_BASE_PACKAGES[@]}"; then
    nova_phase1_error "APT base package installation failed."
    return 1
  fi
  nova_phase1_ok "Base package installation completed."
}

nova_phase2_verify_packages() {
  local package status
  local missing=0

  for package in "${NOVA_PHASE2_BASE_PACKAGES[@]}"; do
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)"
    if [[ "$status" != "ii " ]]; then
      nova_phase1_error "Required base package is unavailable after installation: ${package}"
      missing=1
    fi
  done
  (( missing == 0 ))
  nova_phase1_ok "All required Phase 2 packages are installed."
}

nova_phase2_verify_commands() {
  local command_name
  local missing=0
  local -a commands=(curl dig git gpg ip jq nft ping rsync ss sudo sysctl unbound unbound-checkconf unzip wg xz)

  for command_name in "${commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      nova_phase1_error "Expected command is unavailable after base package installation: ${command_name}"
      missing=1
    fi
  done
  (( missing == 0 ))

  if ! nova_phase2_unit_exists "unbound.service"; then
    nova_phase1_error "Expected systemd unit is unavailable after package installation: unbound.service"
    return 1
  fi
  if ! nova_phase2_unit_exists "nftables.service"; then
    nova_phase1_error "Expected systemd unit is unavailable after package installation: nftables.service"
    return 1
  fi
  nova_phase1_ok "Required commands and package-provided systemd units are available."
}

nova_phase2_prepare_directory() {
  local directory="$1"
  local mode="$2"

  if [[ ! -d "$directory" ]]; then
    mkdir -- "$directory"
  fi
  chmod "$mode" -- "$directory"
  if ! nova_phase2_is_test_mode; then
    chown root:root -- "$directory"
  fi
}

nova_phase2_install_file_if_changed() {
  local temporary_file="$1"
  local target_file="$2"
  local mode="$3"

  chmod "$mode" -- "$temporary_file"
  if [[ -f "$target_file" ]] && cmp -s -- "$temporary_file" "$target_file"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$target_file"
  fi
  chmod "$mode" -- "$target_file"
  if ! nova_phase2_is_test_mode; then
    chown root:root -- "$target_file"
  fi
}

nova_phase2_download_key() {
  local url="$1"
  local target_file="$2"
  local temporary_file

  temporary_file="$(mktemp "${target_file}.XXXXXX")"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --output "$temporary_file" "$url"; then
    rm -f -- "$temporary_file"
    nova_phase1_error "Could not download an official APT repository key."
    return 1
  fi
  if [[ ! -s "$temporary_file" ]] || ! gpg --batch --quiet --show-keys "$temporary_file" >/dev/null 2>&1; then
    rm -f -- "$temporary_file"
    nova_phase1_error "Downloaded APT repository key is empty or invalid."
    return 1
  fi

  nova_phase2_install_file_if_changed "$temporary_file" "$target_file" 0644
}

nova_phase2_write_repository_file() {
  local target_file="$1"
  local content="$2"
  local temporary_file

  temporary_file="$(mktemp "${target_file}.XXXXXX")"
  printf '%s\n' "$content" > "$temporary_file"
  nova_phase2_install_file_if_changed "$temporary_file" "$target_file" 0644
}

nova_phase2_configure_external_repositories() {
  local keyring_dir sources_dir architecture docker_content syncthing_content

  nova_phase1_info "Preparing official Docker and Syncthing APT repositories without installing their applications."
  nova_phase2_check_repository_duplicates

  architecture="$(dpkg --print-architecture)"
  if [[ "$architecture" != "arm64" ]]; then
    nova_phase1_error "Docker repository preparation requires the supported arm64 dpkg architecture."
    return 1
  fi

  keyring_dir="$(nova_phase1_root_path "/etc/apt/keyrings")"
  sources_dir="$(nova_phase1_root_path "/etc/apt/sources.list.d")"
  nova_phase2_prepare_directory "$keyring_dir" 0755

  nova_phase2_download_key "$NOVA_PHASE2_DOCKER_KEY_URL" "${keyring_dir}/docker.asc"
  nova_phase2_download_key "$NOVA_PHASE2_SYNCTHING_KEY_URL" \
    "${keyring_dir}/syncthing-archive-keyring.gpg"

  docker_content="Types: deb
URIs: ${NOVA_PHASE2_DOCKER_REPOSITORY_URL}
Suites: trixie
Components: stable
Architectures: arm64
Signed-By: /etc/apt/keyrings/docker.asc"
  syncthing_content="deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] ${NOVA_PHASE2_SYNCTHING_REPOSITORY_URL} syncthing stable-v2"
  nova_phase2_write_repository_file "${sources_dir}/docker.sources" "$docker_content"
  nova_phase2_write_repository_file "${sources_dir}/syncthing.list" "$syncthing_content"
  nova_phase1_ok "Official Docker and Syncthing repository definitions are present exactly once."
}

nova_phase2_verify_resolver_unchanged() {
  local resolver_file current_fingerprint

  resolver_file="$(nova_phase1_root_path "/etc/resolv.conf")"
  current_fingerprint="$(nova_phase2_file_fingerprint "$resolver_file")"
  if [[ "$current_fingerprint" != "$NOVA_PHASE2_RESOLVER_FINGERPRINT" ]]; then
    nova_phase1_error "Resolver configuration changed during Phase 2; refusing to continue."
    return 1
  fi
  nova_phase1_ok "Resolver configuration is unchanged; no DNS transition was performed."
}

nova_phase2_write_completion_marker() {
  local state_dir marker temporary_file

  state_dir="$(nova_phase1_root_path "/var/lib/nova-infra")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE2_MARKER_RELATIVE_PATH}")"
  nova_phase2_prepare_directory "$state_dir" 0755
  temporary_file="$(mktemp "${state_dir}/.phase2-complete.XXXXXX")"
  printf '%s\n' 'phase=2' > "$temporary_file"
  nova_phase2_install_file_if_changed "$temporary_file" "$marker" 0644
}

nova_phase2_preflight() {
  local resolver_file

  nova_phase1_info "Phase 2 preflight checks"
  nova_phase2_require_commands
  nova_phase2_check_safe_paths
  nova_phase2_check_repository_duplicates
  resolver_file="$(nova_phase1_root_path "/etc/resolv.conf")"
  NOVA_PHASE2_RESOLVER_FINGERPRINT="$(nova_phase2_file_fingerprint "$resolver_file")"
  nova_phase2_prepare_service_safety
  nova_phase1_ok "Phase 2 preflight and service-start protection completed."
}

nova_phase2_main() {
  trap nova_phase2_best_effort_cleanup EXIT
  nova_phase2_preflight
  nova_phase2_run_apt_update
  nova_phase2_run_full_upgrade
  nova_phase2_install_base_packages
  nova_phase2_verify_packages
  nova_phase2_verify_commands
  nova_phase2_configure_external_repositories
  nova_phase2_run_apt_update
  nova_phase1_info "Checking critical package service safety."
  nova_phase2_enforce_service_safety
  nova_phase2_verify_resolver_unchanged
  nova_phase2_write_completion_marker
  trap - EXIT

  if [[ -e "$(nova_phase1_root_path "/var/run/reboot-required")" ]]; then
    nova_phase1_warn "A reboot is required to complete installed system updates; Phase 2 does not reboot automatically."
  fi
  nova_phase1_ok "Phase 2 completed. No Phase 3 services or workloads were configured or activated."
}
