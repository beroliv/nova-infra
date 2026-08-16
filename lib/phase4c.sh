#!/usr/bin/env bash

# Phase 4c only: wg-easy v15 WireGuard service, unattended one-time bootstrap,
# persistent state, and LAN-reachable web UI exposure. Caddy remains out of scope.

readonly NOVA_PHASE4C_IMAGE="ghcr.io/wg-easy/wg-easy:15"
readonly NOVA_PHASE4C_COMPOSE_SOURCE="${NOVA_INSTALLER_DIR}/compose/wg-easy/compose.yml"
readonly NOVA_PHASE4C_INIT_SOURCE="${NOVA_INSTALLER_DIR}/compose/wg-easy/compose.init.yml"
readonly NOVA_PHASE4C_INSTALL_DIR_RELATIVE_PATH="opt/wg-easy"
readonly NOVA_PHASE4C_COMPOSE_RELATIVE_PATH="opt/wg-easy/compose.yml"
readonly NOVA_PHASE4C_DATA_RELATIVE_PATH="opt/wg-easy/data"
readonly NOVA_PHASE4C_DATABASE_RELATIVE_PATH="opt/wg-easy/data/wg-easy.db"
readonly NOVA_PHASE4C_MARKER_RELATIVE_PATH="var/lib/nova-infra/phase4c-complete"

NOVA_PHASE4C_RESOLVER_FINGERPRINT=""
NOVA_PHASE4C_UNBOUND_MAIN_FINGERPRINT=""
NOVA_PHASE4C_UNBOUND_NOVA_FINGERPRINT=""

nova_phase4c_require_commands() {
  local command_name
  local missing=0
  local -a commands=(chmod chown cmp cp curl dirname docker grep mkdir mktemp mv rm sleep stat)

  for command_name in "${commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      nova_phase1_error "Required Phase 4c command is missing: ${command_name}"
      missing=1
    fi
  done
  (( missing == 0 ))
}

nova_phase4c_require_phase4b() {
  local marker

  marker="$(nova_phase1_root_path "/${NOVA_PHASE4B_MARKER_RELATIVE_PATH}")"
  if [[ ! -f "$marker" || -L "$marker" ]] || ! grep -Fxq 'phase=4b' "$marker"; then
    nova_phase1_error "Phase 4c requires a successfully completed Phase 4b marker."
    return 1
  fi
  nova_phase1_ok "Phase 4b is complete."
}

nova_phase4c_check_safe_paths() {
  local local_secrets install_dir data_dir compose_target marker source entry path display optional
  local -a directories files

  local_secrets="$(nova_phase1_root_path "/${NOVA_PHASE1_LOCAL_SECRET_RELATIVE_PATH}")"
  install_dir="$(nova_phase1_root_path "/${NOVA_PHASE4C_INSTALL_DIR_RELATIVE_PATH}")"
  data_dir="$(nova_phase1_root_path "/${NOVA_PHASE4C_DATA_RELATIVE_PATH}")"
  compose_target="$(nova_phase1_root_path "/${NOVA_PHASE4C_COMPOSE_RELATIVE_PATH}")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE4C_MARKER_RELATIVE_PATH}")"
  directories=(
    "$(nova_phase1_root_path "/opt")|/opt|0"
    "${install_dir}|/opt/wg-easy|1"
    "${data_dir}|/opt/wg-easy/data|1"
  )
  files=(
    "${compose_target}|/opt/wg-easy/compose.yml"
    "$(nova_phase1_root_path "/${NOVA_PHASE4C_DATABASE_RELATIVE_PATH}")|/opt/wg-easy/data/wg-easy.db"
    "${marker}|/var/lib/nova-infra/phase4c-complete"
  )

  for source in "$NOVA_PHASE4C_COMPOSE_SOURCE" "$NOVA_PHASE4C_INIT_SOURCE"; do
    if [[ ! -f "$source" || -L "$source" ]]; then
      nova_phase1_error "A repository-managed Phase 4c Compose source is missing or unsafe."
      return 1
    fi
  done
  if [[ ! -f "$local_secrets" || -L "$local_secrets" ]]; then
    nova_phase1_error "Phase 1 local secrets file is missing or unsafe."
    return 1
  fi
  for entry in "${directories[@]}"; do
    IFS='|' read -r path display optional <<< "$entry"
    nova_phase2_assert_safe_directory "$path" "$display" "$optional"
  done
  for entry in "${files[@]}"; do
    IFS='|' read -r path display <<< "$entry"
    nova_phase2_assert_safe_file_target "$path" "$display"
  done
  nova_phase1_ok "Phase 4c Compose, persistent-data, secret-source, and state paths passed safety checks."
}

nova_phase4c_capture_network_fingerprints() {
  NOVA_PHASE4C_RESOLVER_FINGERPRINT="$(
    nova_phase2_file_fingerprint "$(nova_phase1_root_path "/etc/resolv.conf")"
  )"
  NOVA_PHASE4C_UNBOUND_MAIN_FINGERPRINT="$(
    nova_phase2_file_fingerprint "$(nova_phase1_root_path "/etc/unbound/unbound.conf")"
  )"
  NOVA_PHASE4C_UNBOUND_NOVA_FINGERPRINT="$(
    nova_phase2_file_fingerprint "$(nova_phase1_root_path "/etc/unbound/unbound.conf.d/nova.conf")"
  )"
}

nova_phase4c_verify_network_files_unchanged() {
  local resolver unbound_main unbound_nova

  resolver="$(nova_phase2_file_fingerprint "$(nova_phase1_root_path "/etc/resolv.conf")")"
  unbound_main="$(nova_phase2_file_fingerprint "$(nova_phase1_root_path "/etc/unbound/unbound.conf")")"
  unbound_nova="$(
    nova_phase2_file_fingerprint "$(nova_phase1_root_path "/etc/unbound/unbound.conf.d/nova.conf")"
  )"
  if [[ "$resolver" != "$NOVA_PHASE4C_RESOLVER_FINGERPRINT" \
    || "$unbound_main" != "$NOVA_PHASE4C_UNBOUND_MAIN_FINGERPRINT" \
    || "$unbound_nova" != "$NOVA_PHASE4C_UNBOUND_NOVA_FINGERPRINT" ]]; then
    nova_phase1_error "Resolver or Unbound configuration changed during Phase 4c."
    return 1
  fi
  nova_phase1_ok "Resolver and Unbound configuration remain unchanged."
}

nova_phase4c_read_password() {
  local result_name="$1"
  local local_secrets value

  local_secrets="$(nova_phase1_root_path "/${NOVA_PHASE1_LOCAL_SECRET_RELATIVE_PATH}")"
  value="$(nova_phase1_read_assignment "$local_secrets" WG_EASY_PASSWORD || true)"
  printf -v "$result_name" '%s' "$value"
}

nova_phase4c_prepare_directory() {
  local directory="$1"
  local mode="$2"

  if [[ ! -e "$directory" ]]; then
    mkdir -- "$directory"
  fi
  chmod "$mode" -- "$directory"
  chown root:root -- "$directory"
}

nova_phase4c_install_compose() {
  local install_dir target temporary_file

  install_dir="$(nova_phase1_root_path "/${NOVA_PHASE4C_INSTALL_DIR_RELATIVE_PATH}")"
  target="$(nova_phase1_root_path "/${NOVA_PHASE4C_COMPOSE_RELATIVE_PATH}")"
  temporary_file="$(mktemp "${install_dir}/.compose.yml.candidate.XXXXXX")"
  if ! cp -- "$NOVA_PHASE4C_COMPOSE_SOURCE" "$temporary_file"; then
    rm -f -- "$temporary_file"
    nova_phase1_error "Could not stage the wg-easy Compose file."
    return 1
  fi
  chmod 0644 -- "$temporary_file"
  if [[ -f "$target" ]] && cmp -s -- "$temporary_file" "$target"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$target"
  fi
  chmod 0644 -- "$target"
  chown root:root -- "$target"
}

nova_phase4c_compose() {
  local compose_file

  compose_file="$(nova_phase1_root_path "/${NOVA_PHASE4C_COMPOSE_RELATIVE_PATH}")"
  docker compose --project-name wg-easy -f "$compose_file" "$@"
}

nova_phase4c_container_exists() {
  docker inspect wg-easy >/dev/null 2>&1
}

nova_phase4c_check_existing_container() {
  local project

  if ! nova_phase4c_container_exists; then
    return 0
  fi
  project="$(
    docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' wg-easy 2>/dev/null || true
  )"
  if [[ "$project" != "wg-easy" ]]; then
    nova_phase1_error "An unmanaged container named wg-easy already exists; refusing destructive replacement."
    return 1
  fi
  nova_phase1_ok "Existing wg-easy container belongs to the managed Compose project."
}

nova_phase4c_wait_for_initial_state() {
  local database attempt

  database="$(nova_phase1_root_path "/${NOVA_PHASE4C_DATABASE_RELATIVE_PATH}")"
  for (( attempt = 1; attempt <= 30; attempt++ )); do
    if [[ -s "$database" ]] \
      && docker exec wg-easy test -s /etc/wireguard/wg-easy.db >/dev/null 2>&1 \
      && docker exec wg-easy test -s /etc/wireguard/wg0.conf >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  nova_phase1_error "wg-easy did not finish unattended initialization within 30 seconds."
  return 1
}

nova_phase4c_verify_init_secret_removed() {
  local password="$1"
  local environment

  if ! environment="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' wg-easy)"; then
    nova_phase1_error "Could not inspect the wg-easy runtime environment."
    return 1
  fi
  if grep -Eq '^INIT_(USERNAME|PASSWORD|HOST|PORT|DNS|IPV4_CIDR|IPV6_CIDR|ALLOWED_IPS)=' \
    <<< "$environment" || [[ "$environment" == *"$password"* ]]; then
    nova_phase1_error "One-time wg-easy initialization credentials remain in the runtime environment."
    return 1
  fi
  nova_phase1_ok "One-time initialization variables were removed from the running container."
}

nova_phase4c_initialise() {
  local password="$1"

  nova_phase1_info "Performing unattended wg-easy v15 initialization without logging credentials."
  if ! WG_EASY_PASSWORD="$password" docker compose --project-name wg-easy \
    -f "$(nova_phase1_root_path "/${NOVA_PHASE4C_COMPOSE_RELATIVE_PATH}")" \
    -f "$NOVA_PHASE4C_INIT_SOURCE" config --quiet >/dev/null; then
    nova_phase1_error "wg-easy unattended Compose configuration is invalid."
    return 1
  fi
  if ! WG_EASY_PASSWORD="$password" docker compose --project-name wg-easy \
    -f "$(nova_phase1_root_path "/${NOVA_PHASE4C_COMPOSE_RELATIVE_PATH}")" \
    -f "$NOVA_PHASE4C_INIT_SOURCE" up -d >/dev/null; then
    nova_phase4c_compose down >/dev/null 2>&1 || true
    nova_phase1_error "wg-easy unattended initialization failed."
    return 1
  fi
  if ! nova_phase4c_wait_for_initial_state; then
    nova_phase4c_compose down >/dev/null 2>&1 || true
    return 1
  fi
  if ! nova_phase4c_compose up -d --force-recreate >/dev/null; then
    nova_phase4c_compose down >/dev/null 2>&1 || true
    nova_phase1_error "Could not recreate wg-easy without one-time initialization variables."
    return 1
  fi
  nova_phase4c_verify_init_secret_removed "$password"
}

nova_phase4c_deploy() {
  local password="$1"
  local install_dir data_dir database

  install_dir="$(nova_phase1_root_path "/${NOVA_PHASE4C_INSTALL_DIR_RELATIVE_PATH}")"
  data_dir="$(nova_phase1_root_path "/${NOVA_PHASE4C_DATA_RELATIVE_PATH}")"
  database="$(nova_phase1_root_path "/${NOVA_PHASE4C_DATABASE_RELATIVE_PATH}")"
  nova_phase4c_prepare_directory "$install_dir" 0755
  nova_phase4c_prepare_directory "$data_dir" 0700
  nova_phase4c_install_compose

  if ! nova_phase4c_compose config --quiet >/dev/null; then
    nova_phase1_error "Installed wg-easy Compose configuration is invalid."
    return 1
  fi
  nova_phase4c_check_existing_container
  nova_phase1_info "Pulling the pinned wg-easy v15 major image."
  if ! nova_phase4c_compose pull >/dev/null; then
    nova_phase1_error "Could not pull ${NOVA_PHASE4C_IMAGE}; no fallback image will be used."
    return 1
  fi

  if [[ ! -s "$database" ]]; then
    nova_phase4c_initialise "$password"
  else
    nova_phase1_info "Existing persistent wg-easy state found; unattended initialization is not repeated."
    # Recreate from the permanent Compose file so one-time INIT_* variables
    # from an older container definition cannot survive in the runtime.
    if ! nova_phase4c_compose up -d --force-recreate >/dev/null; then
      nova_phase1_error "Could not recreate wg-easy from its persistent state."
      return 1
    fi
    nova_phase4c_verify_init_secret_removed "$password"
  fi
}

nova_phase4c_verify_runtime() {
  local data_dir database running image logs
  local udp_bindings ui_bindings mounts password="$1"

  data_dir="$(nova_phase1_root_path "/${NOVA_PHASE4C_DATA_RELATIVE_PATH}")"
  database="$(nova_phase1_root_path "/${NOVA_PHASE4C_DATABASE_RELATIVE_PATH}")"
  running="$(docker inspect --format '{{.State.Running}}' wg-easy 2>/dev/null || true)"
  image="$(docker inspect --format '{{.Config.Image}}' wg-easy 2>/dev/null || true)"
  if [[ "$running" != "true" || "$image" != "$NOVA_PHASE4C_IMAGE" ]]; then
    nova_phase1_error "wg-easy is not running with the required v15 image."
    return 1
  fi

  logs="$(docker logs --tail 200 wg-easy 2>&1 || true)"
  if grep -Eiq 'ip_tables|iptables.*legacy.*nat|iptables.*legacy.*table' <<< "$logs"; then
    nova_phase1_error "wg-easy reported a legacy iptables kernel compatibility error."
    return 1
  fi

  udp_bindings="$(docker port wg-easy 51824/udp 2>/dev/null || true)"
  ui_bindings="$(docker port wg-easy 51821/tcp 2>/dev/null || true)"
  if [[ "$udp_bindings" != "0.0.0.0:51824" ]]; then
    nova_phase1_error "WireGuard UDP port 51824 is not published as required."
    return 1
  fi
  if [[ "$ui_bindings" != "0.0.0.0:51821" ]]; then
    nova_phase1_error "wg-easy web UI is not published on host port 51821."
    return 1
  fi

  mounts="$(
    docker inspect --format '{{range .Mounts}}{{printf "%s|%s\n" .Source .Destination}}{{end}}' wg-easy \
      2>/dev/null || true
  )"
  if ! grep -Fxq "${data_dir}|/etc/wireguard" <<< "$mounts" || [[ ! -s "$database" ]]; then
    nova_phase1_error "wg-easy persistent storage is missing or mounted incorrectly."
    return 1
  fi
  if ! curl -fsS --max-time 10 --output /dev/null http://127.0.0.1:51821/; then
    nova_phase1_error "wg-easy web UI did not answer on its local endpoint."
    return 1
  fi

  nova_phase1_info "Validating wg-easy container restart with persistent state."
  if ! docker restart wg-easy >/dev/null; then
    nova_phase1_error "wg-easy container restart failed."
    return 1
  fi
  if [[ "$(docker inspect --format '{{.State.Running}}' wg-easy 2>/dev/null || true)" != "true" \
    || ! -s "$database" ]]; then
    nova_phase1_error "wg-easy did not retain its running state and persistent database after restart."
    return 1
  fi
  nova_phase4c_verify_init_secret_removed "$password"
  nova_phase1_ok "wg-easy is running on UDP 51824; its UI is LAN-reachable and persistent state survived restart."
}

nova_phase4c_write_completion_marker() {
  local state_dir marker temporary_file

  state_dir="$(nova_phase1_root_path "/var/lib/nova-infra")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE4C_MARKER_RELATIVE_PATH}")"
  temporary_file="$(mktemp "${state_dir}/.phase4c-complete.XXXXXX")"
  printf '%s\n' 'phase=4c' > "$temporary_file"
  chmod 0644 -- "$temporary_file"
  if [[ -f "$marker" ]] && cmp -s -- "$temporary_file" "$marker"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$marker"
  fi
  chmod 0644 -- "$marker"
  chown root:root -- "$marker"
}

nova_phase4c_preflight() {
  nova_phase1_info "Phase 4c preflight checks"
  nova_phase4c_require_commands
  nova_phase4c_require_phase4b
  nova_phase4c_check_safe_paths
  nova_phase4c_capture_network_fingerprints
  nova_phase1_ok "Phase 4c prerequisites are complete; Caddy, AdGuard, and host firewall policy remain out of scope."
}

nova_phase4c_main() {
  local password=""

  nova_phase4c_preflight
  nova_phase4c_read_password password
  if [[ -z "$password" || "$password" == CHANGE_ME_* ]]; then
    nova_phase4c_write_completion_marker
    nova_phase1_warn "WG_EASY_PASSWORD is unresolved; Phase 4c is incomplete and wg-easy was not started."
    nova_phase1_ok "Phase 4c skipped safely; the remaining installer may continue."
    return 0
  fi

  nova_phase4c_deploy "$password"
  nova_phase4c_verify_runtime "$password"
  nova_phase4c_verify_network_files_unchanged
  nova_phase4c_write_completion_marker
  nova_phase1_ok "Phase 4c completed. wg-easy v15 provides Nova WireGuard without Caddy or AdGuard changes."
}
