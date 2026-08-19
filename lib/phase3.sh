#!/usr/bin/env bash

# Phase 3 only: official Docker Engine packages, systemd startup, administrator
# access, and daemon/API validation. No images or application workloads are
# pulled, created, started, stopped, or removed here.

readonly -a NOVA_PHASE3_DOCKER_PACKAGES=(
  "containerd.io"
  "docker-buildx-plugin"
  "docker-ce"
  "docker-ce-cli"
  "docker-compose-plugin"
)
readonly -a NOVA_PHASE3_INCOMPATIBLE_PACKAGES=(
  "containerd"
  "docker-compose"
  "docker-compose-v2"
  "docker-doc"
  "docker.io"
  "podman-docker"
)
readonly NOVA_PHASE3_DOCKER_REPOSITORY_URL="https://download.docker.com/linux/debian"
readonly NOVA_PHASE3_MARKER_RELATIVE_PATH="var/lib/nova-infra/phase3-complete"

NOVA_PHASE3_RESOLVER_FINGERPRINT=""
NOVA_PHASE3_DOCKER_WAS_INSTALLED=0
NOVA_PHASE3_CONTAINER_SNAPSHOT_AVAILABLE=0
NOVA_PHASE3_CONTAINERS_BEFORE=""
NOVA_PHASE3_ADMIN_GROUP_CHANGED=0

nova_phase3_require_commands() {
  local command_name
  local missing=0
  local -a commands=(apt-cache apt-get dpkg dpkg-query find getent grep id systemctl usermod)

  for command_name in "${commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      nova_phase1_error "Required Phase 3 command is missing: ${command_name}"
      missing=1
    fi
  done

  (( missing == 0 ))
}

nova_phase3_package_is_installed() {
  local package="$1"
  local status

  status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)"
  [[ "$status" == "ii " ]]
}

nova_phase3_require_phase2() {
  local marker keyring repository

  marker="$(nova_phase1_root_path "/${NOVA_PHASE2_MARKER_RELATIVE_PATH}")"
  keyring="$(nova_phase1_root_path "/etc/apt/keyrings/docker.asc")"
  repository="$(nova_phase1_root_path "/etc/apt/sources.list.d/docker.sources")"

  if [[ ! -f "$marker" || -L "$marker" ]] || ! grep -Fxq 'phase=2' "$marker"; then
    nova_phase1_error "Phase 3 requires a successfully completed Phase 2 marker."
    return 1
  fi
  if [[ ! -s "$keyring" || -L "$keyring" ]]; then
    nova_phase1_error "Phase 3 requires the Docker repository keyring prepared by Phase 2."
    return 1
  fi
  if [[ ! -f "$repository" || -L "$repository" ]]; then
    nova_phase1_error "Phase 3 requires the Docker repository definition prepared by Phase 2."
    return 1
  fi
  if ! grep -Fxq "URIs: ${NOVA_PHASE3_DOCKER_REPOSITORY_URL}" "$repository" \
    || ! grep -Fxq 'Suites: trixie' "$repository" \
    || ! grep -Fxq 'Architectures: arm64' "$repository" \
    || ! grep -Fxq 'Signed-By: /etc/apt/keyrings/docker.asc' "$repository"; then
    nova_phase1_error "The Docker APT source does not match the Phase 2 official Debian 13 arm64 definition."
    return 1
  fi

  nova_phase2_check_repository_duplicates
  nova_phase1_ok "Phase 2 marker and official Docker repository definition are present."
}

nova_phase3_repair_package_state() {
  local audit_output

  audit_output="$(dpkg --audit 2>/dev/null || true)"
  if [[ -n "$audit_output" ]]; then
    nova_phase1_info "Repairing interrupted Debian package configuration."
    if ! DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
      nova_phase1_error "dpkg --configure -a could not complete the interrupted package configuration."
      return 1
    fi
  fi

  if ! apt-get check >/dev/null 2>&1; then
    nova_phase1_info "Repairing incomplete APT dependencies."
    if ! DEBIAN_FRONTEND=noninteractive apt-get -f install -y; then
      nova_phase1_error "apt-get -f install could not repair the package state."
      return 1
    fi
  fi
}

nova_phase3_validate_admin_user() {
  local passwd_entry username password uid gid gecos home shell group_entry group_name group_gid groups

  if ! passwd_entry="$(getent passwd admin)"; then
    nova_phase1_error "Required target administrator account is missing: admin"
    return 1
  fi
  IFS=: read -r username password uid gid gecos home shell <<< "$passwd_entry"
  if [[ "$username" != "admin" || "$home" != "/home/admin" || "$shell" != "/bin/bash" ]]; then
    nova_phase1_error "The admin account does not match the required home and shell."
    return 1
  fi
  if ! group_entry="$(getent group admin)"; then
    nova_phase1_error "Required primary group is missing: admin"
    return 1
  fi
  IFS=: read -r group_name _ group_gid _ <<< "$group_entry"
  if [[ "$group_name" != "admin" || "$group_gid" != "$gid" ]]; then
    nova_phase1_error "The admin account primary group must be admin."
    return 1
  fi
  groups="$(id -nG admin)"
  if ! grep -Eq '(^|[[:space:]])sudo([[:space:]]|$)' <<< "$groups"; then
    nova_phase1_error "The admin account must have sudo access through the sudo group."
    return 1
  fi
  nova_phase1_ok "The admin account matches the required home, shell, primary group, and sudo access; existing UID/GID preserved."
}

nova_phase3_check_incompatible_installations() {
  local package docker_data
  local incompatible=0

  for package in "${NOVA_PHASE3_INCOMPATIBLE_PACKAGES[@]}"; do
    if nova_phase3_package_is_installed "$package"; then
      nova_phase1_error "Incompatible existing container package detected: ${package}"
      incompatible=1
    fi
  done
  (( incompatible == 0 ))

  if nova_phase3_package_is_installed "docker-ce"; then
    NOVA_PHASE3_DOCKER_WAS_INSTALLED=1
  else
    NOVA_PHASE3_DOCKER_WAS_INSTALLED=0
    if command -v docker >/dev/null 2>&1; then
      nova_phase1_error "An unmanaged Docker-compatible CLI already exists without the expected docker-ce package."
      return 1
    fi
  fi

  docker_data="$(nova_phase1_root_path "/var/lib/docker")"
  if (( NOVA_PHASE3_DOCKER_WAS_INSTALLED == 0 )) \
    && [[ -e "$docker_data" || -L "$docker_data" ]]; then
    if [[ -L "$docker_data" || ! -d "$docker_data" ]]; then
      nova_phase1_error "Ambiguous existing Docker data path detected at /var/lib/docker."
      return 1
    fi
    if [[ -n "$(find "$docker_data" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      nova_phase1_error "Existing Docker data was found without the expected official Docker CE package; refusing replacement."
      return 1
    fi
  fi

  nova_phase1_ok "No incompatible Debian or third-party container package replacement is required."
}

nova_phase3_verify_official_candidates() {
  local package policy
  local missing=0

  nova_phase1_info "Checking official Docker repository package candidates."
  for package in "${NOVA_PHASE3_DOCKER_PACKAGES[@]}"; do
    policy="$(LC_ALL=C apt-cache policy "$package" 2>/dev/null || true)"
    if [[ -z "$policy" ]] \
      || grep -Eq '^[[:space:]]*Candidate:[[:space:]]*\(none\)[[:space:]]*$' <<< "$policy" \
      || ! grep -Eq '^[[:space:]]*Candidate:[[:space:]]*[^[:space:]]+' <<< "$policy" \
      || [[ "$policy" != *"${NOVA_PHASE3_DOCKER_REPOSITORY_URL}"* ]]; then
      nova_phase1_error "No official Docker repository candidate is available for package: ${package}"
      missing=1
    fi
  done
  (( missing == 0 ))
  nova_phase1_ok "All Docker package candidates come from the prepared official repository."
}

nova_phase3_capture_existing_containers() {
  if (( NOVA_PHASE3_DOCKER_WAS_INSTALLED == 1 )) \
    && command -v docker >/dev/null 2>&1 \
    && systemctl is-active --quiet docker.service; then
    if NOVA_PHASE3_CONTAINERS_BEFORE="$(docker ps -aq --no-trunc 2>/dev/null)"; then
      NOVA_PHASE3_CONTAINER_SNAPSHOT_AVAILABLE=1
      nova_phase1_info "Captured the existing Docker container set for non-destructive validation."
    else
      nova_phase1_warn "Could not capture the existing container set before service validation; existing Docker state will still be preserved."
    fi
  fi
}

nova_phase3_install_docker_packages() {
  nova_phase1_info "Installing Docker Engine and Compose from the official Docker repository."
  if ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
    apt-get install -y -qq -o Acquire::Retries=3 \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
      "${NOVA_PHASE3_DOCKER_PACKAGES[@]}"; then
    nova_phase1_error "Official Docker package installation failed; no fallback package will be used."
    return 1
  fi
  nova_phase1_ok "Official Docker packages were installed successfully."
}

nova_phase3_verify_packages() {
  local package
  local missing=0

  for package in "${NOVA_PHASE3_DOCKER_PACKAGES[@]}"; do
    if ! nova_phase3_package_is_installed "$package"; then
      nova_phase1_error "Required official Docker package is unavailable after installation: ${package}"
      missing=1
    fi
  done
  (( missing == 0 ))

  if nova_phase3_package_is_installed "docker.io"; then
    nova_phase1_error "Debian docker.io was installed unexpectedly; refusing silent fallback."
    return 1
  fi
  nova_phase1_ok "All required official Docker packages are installed; docker.io is absent."
}

nova_phase3_enable_services() {
  nova_phase1_info "Enabling and starting containerd and Docker."
  if ! systemctl enable --now containerd.service >/dev/null; then
    nova_phase1_error "Could not enable and start containerd.service."
    return 1
  fi
  if ! systemctl enable --now docker.service >/dev/null; then
    nova_phase1_error "Could not enable and start docker.service."
    return 1
  fi
  nova_phase1_ok "Docker and containerd startup is enabled."
}

nova_phase3_admin_has_docker_group() {
  local group

  for group in $(id -nG admin); do
    if [[ "$group" == "docker" ]]; then
      return 0
    fi
  done
  return 1
}

nova_phase3_configure_admin_access() {
  if ! getent group docker >/dev/null; then
    nova_phase1_error "The official Docker packages did not provide the docker group."
    return 1
  fi

  if nova_phase3_admin_has_docker_group; then
    nova_phase1_ok "admin is already a member of the docker group."
    return 0
  fi

  if ! usermod -aG docker admin; then
    nova_phase1_error "Could not add admin to the docker group."
    return 1
  fi
  if ! nova_phase3_admin_has_docker_group; then
    nova_phase1_error "admin docker-group membership could not be verified after update."
    return 1
  fi
  NOVA_PHASE3_ADMIN_GROUP_CHANGED=1
  nova_phase1_ok "admin was added once to the docker group."
  nova_phase1_warn "A new login session is required before admin can use Docker without sudo."
}

nova_phase3_verify_services() {
  local unit

  for unit in containerd.service docker.service; do
    if [[ "$(nova_phase2_read_unit_state is-enabled "$unit")" != "enabled" ]]; then
      nova_phase1_error "Required container service is not enabled: ${unit}"
      return 1
    fi
    if ! systemctl is-active --quiet "$unit"; then
      nova_phase1_error "Required container service is not active: ${unit}"
      return 1
    fi
  done
  nova_phase1_ok "docker.service and containerd.service are enabled and active."
}

nova_phase3_verify_docker_api() {
  local docker_version compose_version server_version containers_after

  if ! command -v docker >/dev/null 2>&1; then
    nova_phase1_error "Docker CLI is unavailable after package installation."
    return 1
  fi
  if ! docker_version="$(docker --version)"; then
    nova_phase1_error "docker --version failed."
    return 1
  fi
  if ! docker version >/dev/null 2>&1; then
    nova_phase1_error "docker version failed."
    return 1
  fi
  if ! compose_version="$(docker compose version)"; then
    nova_phase1_error "docker compose version failed."
    return 1
  fi
  if ! server_version="$(docker info --format '{{.ServerVersion}}')" || [[ -z "$server_version" ]]; then
    nova_phase1_error "Docker daemon communication failed."
    return 1
  fi
  if ! docker ps >/dev/null; then
    nova_phase1_error "docker ps failed."
    return 1
  fi
  if ! containers_after="$(docker ps -aq --no-trunc)"; then
    nova_phase1_error "Could not inspect the Docker container set."
    return 1
  fi

  if (( NOVA_PHASE3_DOCKER_WAS_INSTALLED == 0 )) && [[ -n "$containers_after" ]]; then
    nova_phase1_error "Unexpected containers appeared during the initial Phase 3 installation."
    return 1
  fi
  if (( NOVA_PHASE3_CONTAINER_SNAPSHOT_AVAILABLE == 1 )) \
    && [[ "$containers_after" != "$NOVA_PHASE3_CONTAINERS_BEFORE" ]]; then
    nova_phase1_error "The existing Docker container set changed during Phase 3."
    return 1
  fi

  nova_phase1_ok "${docker_version}"
  nova_phase1_ok "${compose_version}"
  nova_phase1_ok "Docker daemon API and docker ps are available; no application workload was created."
}

nova_phase3_verify_resolver_unchanged() {
  local resolver_file current_fingerprint

  resolver_file="$(nova_phase1_root_path "/etc/resolv.conf")"
  current_fingerprint="$(nova_phase2_file_fingerprint "$resolver_file")"
  if [[ "$current_fingerprint" != "$NOVA_PHASE3_RESOLVER_FINGERPRINT" ]]; then
    nova_phase1_error "Resolver configuration changed during Phase 3; refusing to continue."
    return 1
  fi
  nova_phase1_ok "Resolver configuration is unchanged; Phase 3 performed no DNS transition."
}

nova_phase3_write_completion_marker() {
  local state_dir marker temporary_file

  state_dir="$(nova_phase1_root_path "/var/lib/nova-infra")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE3_MARKER_RELATIVE_PATH}")"
  nova_phase2_assert_safe_directory "$state_dir" "/var/lib/nova-infra"
  nova_phase2_assert_safe_file_target "$marker" "/var/lib/nova-infra/phase3-complete"
  temporary_file="$(mktemp "${state_dir}/.phase3-complete.XXXXXX")"
  printf '%s\n' 'phase=3' > "$temporary_file"
  nova_phase2_install_file_if_changed "$temporary_file" "$marker" 0644
}

nova_phase3_preflight() {
  local resolver_file

  nova_phase1_info "Phase 3 preflight checks"
  nova_phase3_require_commands
  nova_phase3_require_phase2
  nova_phase3_repair_package_state
  nova_phase3_validate_admin_user
  nova_phase3_check_incompatible_installations
  nova_phase3_verify_official_candidates
  resolver_file="$(nova_phase1_root_path "/etc/resolv.conf")"
  NOVA_PHASE3_RESOLVER_FINGERPRINT="$(nova_phase2_file_fingerprint "$resolver_file")"
  nova_phase3_capture_existing_containers
  nova_phase1_ok "Phase 3 preflight completed without replacing existing Docker state."
}

nova_phase3_main() {
  nova_phase3_preflight
  nova_phase3_install_docker_packages
  nova_phase3_verify_packages
  nova_phase3_enable_services
  nova_phase3_configure_admin_access
  nova_phase1_info "Validating Docker services, CLI, Compose, daemon API, and container state."
  nova_phase3_verify_services
  nova_phase3_verify_docker_api
  nova_phase3_verify_resolver_unchanged
  nova_phase3_write_completion_marker

  if (( NOVA_PHASE3_ADMIN_GROUP_CHANGED == 0 )); then
    nova_phase1_info "admin already had Docker access; no group membership change was required."
  fi
  nova_phase1_ok "Phase 3 completed. No images, containers, application workloads, DNS, or firewall policy were configured."
}
