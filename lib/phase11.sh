#!/usr/bin/env bash

# Phase 11: enable Debian's standard unattended-upgrades mechanism.

readonly NOVA_PHASE11_PERIODIC_RELATIVE_PATH="etc/apt/apt.conf.d/20auto-upgrades"
readonly NOVA_PHASE11_SERVICE="unattended-upgrades.service"

nova_phase11_require_commands() {
  local command_name missing=0
  for command_name in chmod chown cmp dpkg-reconfigure mkdir mktemp mv rm systemctl; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      nova_phase1_error "Required unattended-upgrades command is missing: ${command_name}"
      missing=1
    fi
  done
  (( missing == 0 ))
}

nova_phase11_write_periodic_config() {
  local config temporary_file
  config="$(nova_phase1_root_path "/${NOVA_PHASE11_PERIODIC_RELATIVE_PATH}")"
  temporary_file="$(mktemp "${config}.candidate.XXXXXX")"
  printf '%s\n' \
    'APT::Periodic::Update-Package-Lists "1";' \
    'APT::Periodic::Unattended-Upgrade "1";' >"$temporary_file"
  chmod 0644 -- "$temporary_file"
  chown root:root -- "$temporary_file"
  if [[ -f "$config" ]] && cmp -s -- "$temporary_file" "$config"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$config"
  fi
  chmod 0644 -- "$config"
  chown root:root -- "$config"
}

nova_phase11_main() {
  local apt_dir
  nova_phase1_info "Phase 11 unattended-upgrades"
  nova_phase11_require_commands
  apt_dir="$(nova_phase1_root_path "/etc/apt/apt.conf.d")"
  mkdir -p -- "$apt_dir"
  DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || {
    nova_phase1_error "Could not configure unattended-upgrades using Debian's standard mechanism."
    return 1
  }
  nova_phase11_write_periodic_config
  if ! systemctl cat "$NOVA_PHASE11_SERVICE" >/dev/null 2>&1; then
    nova_phase1_error "${NOVA_PHASE11_SERVICE} is not available."
    return 1
  fi
  systemctl enable --now "$NOVA_PHASE11_SERVICE"
  nova_phase1_ok "Unattended upgrades and Debian periodic APT updates are enabled."
}
