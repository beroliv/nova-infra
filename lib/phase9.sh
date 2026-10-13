#!/usr/bin/env bash

# Phase 9: deploy the Prusa camera upload and simple reachability monitor.

readonly NOVA_PHASE9_INSTALL_DIR_RELATIVE_PATH="opt/prusa"
readonly NOVA_PHASE9_COMPOSE_RELATIVE_PATH="opt/prusa/compose.yml"
readonly NOVA_PHASE9_MONITOR_RELATIVE_PATH="opt/prusa/monitor.sh"
readonly NOVA_PHASE9_ENV_RELATIVE_PATH="opt/prusa/prusa.env"
readonly NOVA_PHASE9_SECRETS_RELATIVE_PATH="opt/nova-bootstrap/secrets.env"
readonly NOVA_PHASE9_CAMERA_IMAGE="ghcr.io/s31teg/prusa-rtsp-live:1.0.0"
readonly NOVA_PHASE9_CAMERA_CONTAINER="prusa-rtsp-live"
readonly NOVA_PHASE9_LEGACY_CAMERA_CONTAINER="prusa-connect-rtsp"
readonly NOVA_PHASE9_MONITOR_CONTAINER="prusa-monitor"
readonly NOVA_PHASE9_PRINTER_IP="192.168.0.61"

nova_phase9_require_commands() {
  local command_name missing=0
  for command_name in chmod chown cmp cp docker grep mkdir mktemp mv rm; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      nova_phase1_error "Required Prusa command is missing: ${command_name}"
      missing=1
    fi
  done
  (( missing == 0 ))
}

nova_phase9_prepare_paths() {
  local install_dir
  install_dir="$(nova_phase1_root_path "/${NOVA_PHASE9_INSTALL_DIR_RELATIVE_PATH}")"
  if [[ -e "$install_dir" && ( ! -d "$install_dir" || -L "$install_dir" ) ]]; then
    nova_phase1_error "Prusa path is not a safe directory: ${install_dir}"
    return 1
  fi
  mkdir -p -- "$install_dir"
  chmod 0755 -- "$install_dir"
  chown root:root -- "$install_dir"
}

nova_phase9_read_secrets() {
  local secrets_file value unresolved=()
  secrets_file="$(nova_phase1_root_path "/${NOVA_PHASE9_SECRETS_RELATIVE_PATH}")"
  for name in CAMERA_URL TOKEN; do
    value="$(nova_phase1_read_assignment "$secrets_file" "$name" || true)"
    if [[ -z "$value" || "$value" == CHANGE_ME_* ]]; then
      unresolved+=("$name")
    fi
  done
  if (( ${#unresolved[@]} > 0 )); then
    nova_phase1_warn "Unresolved Prusa secret variables: ${unresolved[*]}; camera stack not started."
    return 1
  fi
}

nova_phase9_write_monitor() {
  local monitor temporary_file
  monitor="$(nova_phase1_root_path "/${NOVA_PHASE9_MONITOR_RELATIVE_PATH}")"
  temporary_file="$(mktemp "${monitor}.candidate.XXXXXX")"
  {
    printf '%s\n' '#!/bin/sh' 'set -eu' '' 'while :; do'
    printf '%s\n' '  if ping -c 1 -W 2 192.168.0.61 >/dev/null 2>&1; then'
    printf '%s\n' '    running="$(docker inspect -f '\''{{.State.Running}}'\'' prusa-rtsp-live 2>/dev/null || true)"'
    printf '%s\n' '    if [ "$running" != "true" ]; then'
    printf '%s\n' '      docker start prusa-rtsp-live >/dev/null 2>&1 || true'
    printf '%s\n' '    fi'
    printf '%s\n' '  else'
    printf '%s\n' '    docker stop prusa-rtsp-live >/dev/null 2>&1 || true'
    printf '%s\n' '  fi'
    printf '%s\n' '  sleep 30' 'done'
  } >"$temporary_file"
  chmod 0755 -- "$temporary_file"
  chown root:root -- "$temporary_file"
  if [[ -f "$monitor" ]] && cmp -s -- "$temporary_file" "$monitor"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$monitor"
  fi
  chmod 0755 -- "$monitor"
  chown root:root -- "$monitor"
}

nova_phase9_write_env() {
  local secrets_file env_file temporary_file camera_url token existing_value
  secrets_file="$(nova_phase1_root_path "/${NOVA_PHASE9_SECRETS_RELATIVE_PATH}")"
  env_file="$(nova_phase1_root_path "/${NOVA_PHASE9_ENV_RELATIVE_PATH}")"
  camera_url="$(nova_phase1_read_assignment "$secrets_file" CAMERA_URL)"
  token="$(nova_phase1_read_assignment "$secrets_file" TOKEN)"
  if [[ -f "$env_file" && ! -L "$env_file" ]]; then
    existing_value="$(nova_phase1_read_assignment "$env_file" CAMERA_URL || true)"
    [[ -n "$existing_value" && "$existing_value" != CHANGE_ME_* ]] && camera_url="$existing_value"
    existing_value="$(nova_phase1_read_assignment "$env_file" PRUSA_TOKEN || true)"
    if [[ -z "$existing_value" || "$existing_value" == CHANGE_ME_* ]]; then
      existing_value="$(nova_phase1_read_assignment "$env_file" TOKENS || true)"
    fi
    [[ -n "$existing_value" && "$existing_value" != CHANGE_ME_* ]] && token="$existing_value"
  fi
  temporary_file="$(mktemp "${env_file}.candidate.XXXXXX")"
  {
    printf 'CAMERA_URL=%s\n' "$camera_url"
    printf 'PRUSA_TOKEN=%s\n' "$token"
  } >"$temporary_file"
  chmod 0600 -- "$temporary_file"
  chown root:root -- "$temporary_file"
  if [[ -f "$env_file" ]] && cmp -s -- "$temporary_file" "$env_file"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$env_file"
  fi
  chmod 0600 -- "$env_file"
  chown root:root -- "$env_file"
}

nova_phase9_write_compose() {
  local compose temporary_file
  compose="$(nova_phase1_root_path "/${NOVA_PHASE9_COMPOSE_RELATIVE_PATH}")"
  temporary_file="$(mktemp "${compose}.candidate.XXXXXX")"
  {
    printf '%s\n' \
      'services:' \
      '  prusa-rtsp-live:' \
      '    image: ghcr.io/s31teg/prusa-rtsp-live:1.0.0' \
      '    container_name: prusa-rtsp-live' \
      '    restart: "no"' \
      '    network_mode: host' \
      '    env_file:' \
      '      - path: /opt/prusa/prusa.env' \
      '        format: raw' \
      '    environment:' \
      '      MODE: buddy3d' \
      '      FINGERPRINT: camera0000000001' \
      '      SNAPSHOTS: "true"' \
      '      LIVE: "false"' \
      '      TZ: Europe/Zurich' \
      '  prusa-monitor:' \
      '    image: alpine:latest' \
      '    container_name: prusa-monitor' \
      '    restart: unless-stopped' \
      '    volumes:' \
      '      - /var/run/docker.sock:/var/run/docker.sock' \
      '      - /opt/prusa/monitor.sh:/monitor.sh:ro' \
      '    command:' \
      '      - /bin/sh' \
      '      - -c' \
      '      - apk add --no-cache iputils docker-cli >/dev/null && exec /monitor.sh'
  } >"$temporary_file"
  chmod 0644 -- "$temporary_file"
  chown root:root -- "$temporary_file"
  if [[ -f "$compose" ]] && cmp -s -- "$temporary_file" "$compose"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$compose"
  fi
  chmod 0644 -- "$compose"
  chown root:root -- "$compose"
}

nova_phase9_remove_legacy_container() {
  if docker inspect "$NOVA_PHASE9_LEGACY_CAMERA_CONTAINER" >/dev/null 2>&1; then
    nova_phase1_info "Removing the obsolete ${NOVA_PHASE9_LEGACY_CAMERA_CONTAINER} container."
    if ! docker rm -f "$NOVA_PHASE9_LEGACY_CAMERA_CONTAINER" >/dev/null; then
      nova_phase1_error "Could not remove the obsolete ${NOVA_PHASE9_LEGACY_CAMERA_CONTAINER} container."
      return 1
    fi
  fi
}

nova_phase9_deploy() {
  local install_dir compose
  install_dir="$(nova_phase1_root_path "/${NOVA_PHASE9_INSTALL_DIR_RELATIVE_PATH}")"
  compose="$(nova_phase1_root_path "/${NOVA_PHASE9_COMPOSE_RELATIVE_PATH}")"
  if ! docker compose --project-directory "$install_dir" -f "$compose" config --quiet; then
    nova_phase1_error "Prusa Docker Compose configuration is invalid."
    return 1
  fi
  nova_phase9_remove_legacy_container
  nova_phase1_info "Starting the Prusa camera and monitor containers."
  if ! docker compose --project-directory "$install_dir" -f "$compose" up -d; then
    nova_phase1_error "Prusa camera stack deployment failed."
    return 1
  fi
}

nova_phase9_main() {
  nova_phase1_info "Phase 9 Prusa camera containers"
  nova_phase9_require_commands
  nova_phase9_prepare_paths
  if ! nova_phase9_read_secrets; then
    return 0
  fi
  nova_phase9_write_env
  nova_phase9_write_monitor
  nova_phase9_write_compose
  nova_phase9_deploy
}
