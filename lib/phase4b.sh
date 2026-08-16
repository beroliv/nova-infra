#!/usr/bin/env bash

# Phase 4b only: FreeDNS DynDNS script, root-only runtime secret, and the
# specified systemd oneshot service/timer schedule.

readonly NOVA_PHASE4B_SCRIPT_SOURCE="${NOVA_INSTALLER_DIR}/scripts/dyndns-update.sh"
readonly NOVA_PHASE4B_SERVICE_SOURCE="${NOVA_INSTALLER_DIR}/systemd/dyndns.service"
readonly NOVA_PHASE4B_TIMER_SOURCE="${NOVA_INSTALLER_DIR}/systemd/dyndns.timer"
readonly NOVA_PHASE4B_SCRIPT_RELATIVE_PATH="usr/local/bin/dyndns-update.sh"
readonly NOVA_PHASE4B_SERVICE_RELATIVE_PATH="etc/systemd/system/dyndns.service"
readonly NOVA_PHASE4B_TIMER_RELATIVE_PATH="etc/systemd/system/dyndns.timer"
readonly NOVA_PHASE4B_RUNTIME_DIR_RELATIVE_PATH="etc/nova-infra"
readonly NOVA_PHASE4B_RUNTIME_SECRET_RELATIVE_PATH="etc/nova-infra/dyndns.env"
readonly NOVA_PHASE4B_MARKER_RELATIVE_PATH="var/lib/nova-infra/phase4b-complete"

NOVA_PHASE4B_UNITS_CHANGED=0

nova_phase4b_require_commands() {
  local command_name
  local missing=0
  local -a commands=(bash basename chmod cmp cp curl dirname grep mkdir mktemp mv rm stat systemctl systemd-analyze)

  for command_name in "${commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      nova_phase1_error "Required Phase 4b command is missing: ${command_name}"
      missing=1
    fi
  done
  (( missing == 0 ))
}

nova_phase4b_require_phase4a() {
  local marker

  marker="$(nova_phase1_root_path "/${NOVA_PHASE4A_MARKER_RELATIVE_PATH}")"
  if [[ ! -f "$marker" || -L "$marker" ]] || ! grep -Fxq 'phase=4a' "$marker"; then
    nova_phase1_error "Phase 4b requires a successfully completed Phase 4a marker."
    return 1
  fi
  nova_phase1_ok "Phase 4a is complete."
}

nova_phase4b_check_safe_paths() {
  local local_secrets runtime_dir marker source target
  local -a directories sources targets

  local_secrets="$(nova_phase1_root_path "/${NOVA_PHASE1_LOCAL_SECRET_RELATIVE_PATH}")"
  runtime_dir="$(nova_phase1_root_path "/${NOVA_PHASE4B_RUNTIME_DIR_RELATIVE_PATH}")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE4B_MARKER_RELATIVE_PATH}")"
  directories=(
    "$(nova_phase1_root_path "/usr/local/bin")|/usr/local/bin|0"
    "$(nova_phase1_root_path "/etc/systemd/system")|/etc/systemd/system|0"
    "$(nova_phase1_root_path "/etc")|/etc|0"
    "${runtime_dir}|/etc/nova-infra|1"
  )
  sources=("$NOVA_PHASE4B_SCRIPT_SOURCE" "$NOVA_PHASE4B_SERVICE_SOURCE" "$NOVA_PHASE4B_TIMER_SOURCE")
  targets=(
    "$(nova_phase1_root_path "/${NOVA_PHASE4B_SCRIPT_RELATIVE_PATH}")|/usr/local/bin/dyndns-update.sh"
    "$(nova_phase1_root_path "/${NOVA_PHASE4B_SERVICE_RELATIVE_PATH}")|/etc/systemd/system/dyndns.service"
    "$(nova_phase1_root_path "/${NOVA_PHASE4B_TIMER_RELATIVE_PATH}")|/etc/systemd/system/dyndns.timer"
    "$(nova_phase1_root_path "/${NOVA_PHASE4B_RUNTIME_SECRET_RELATIVE_PATH}")|/etc/nova-infra/dyndns.env"
    "${marker}|/var/lib/nova-infra/phase4b-complete"
  )

  for source in "${sources[@]}"; do
    if [[ ! -f "$source" || -L "$source" ]]; then
      nova_phase1_error "A repository-managed Phase 4b source file is missing or unsafe."
      return 1
    fi
  done
  for target in "${directories[@]}"; do
    IFS='|' read -r source target marker <<< "$target"
    nova_phase2_assert_safe_directory "$source" "$target" "$marker"
  done
  for target in "${targets[@]}"; do
    IFS='|' read -r source target <<< "$target"
    nova_phase2_assert_safe_file_target "$source" "$target"
  done
  if [[ ! -f "$local_secrets" || -L "$local_secrets" ]]; then
    nova_phase1_error "Phase 1 local secrets file is missing or unsafe."
    return 1
  fi
  nova_phase1_ok "Phase 4b script, systemd, runtime-secret, and state paths passed safety checks."
}

nova_phase4b_prepare_file() {
  local file="$1"
  local mode="$2"

  chmod "$mode" -- "$file"
  chown root:root -- "$file"
}

nova_phase4b_install_file() {
  local source="$1"
  local target="$2"
  local mode="$3"
  local change_type="$4"
  local target_dir temporary_file

  target_dir="$(dirname -- "$target")"
  temporary_file="$(mktemp "${target_dir}/.$(basename -- "$target").candidate.XXXXXX")"
  if ! cp -- "$source" "$temporary_file"; then
    rm -f -- "$temporary_file"
    nova_phase1_error "Could not stage a Phase 4b managed file."
    return 1
  fi
  nova_phase4b_prepare_file "$temporary_file" "$mode"

  if [[ -f "$target" ]] && cmp -s -- "$temporary_file" "$target"; then
    rm -f -- "$temporary_file"
    nova_phase4b_prepare_file "$target" "$mode"
    return 0
  fi
  if ! mv -f -- "$temporary_file" "$target"; then
    rm -f -- "$temporary_file"
    nova_phase1_error "Could not atomically install a Phase 4b managed file."
    return 1
  fi
  if [[ "$change_type" == "unit" ]]; then
    NOVA_PHASE4B_UNITS_CHANGED=1
  fi
}

nova_phase4b_validate_script_source() {
  nova_phase1_info "Validating the DynDNS script before installation."
  if ! bash -n "$NOVA_PHASE4B_SCRIPT_SOURCE"; then
    nova_phase1_error "Repository-managed DynDNS script failed shell syntax validation."
    return 1
  fi
  nova_phase1_ok "DynDNS script source is valid."
}

nova_phase4b_validate_unit_sources() {
  nova_phase1_info "Validating the DynDNS systemd units before installation."
  if ! systemd-analyze verify "$NOVA_PHASE4B_SERVICE_SOURCE" "$NOVA_PHASE4B_TIMER_SOURCE" >/dev/null; then
    nova_phase1_error "Repository-managed DynDNS systemd units failed validation."
    return 1
  fi
  nova_phase1_ok "DynDNS systemd unit sources are valid."
}

nova_phase4b_install_managed_files() {
  local service_target timer_target

  service_target="$(nova_phase1_root_path "/${NOVA_PHASE4B_SERVICE_RELATIVE_PATH}")"
  timer_target="$(nova_phase1_root_path "/${NOVA_PHASE4B_TIMER_RELATIVE_PATH}")"

  nova_phase4b_install_file "$NOVA_PHASE4B_SERVICE_SOURCE" "$service_target" 0644 unit
  nova_phase4b_install_file "$NOVA_PHASE4B_TIMER_SOURCE" "$timer_target" 0644 unit

  if (( NOVA_PHASE4B_UNITS_CHANGED == 1 )); then
    nova_phase1_info "DynDNS units changed; reloading systemd."
    if ! systemctl daemon-reload; then
      nova_phase1_error "systemd daemon-reload failed after installing DynDNS units."
      return 1
    fi
  else
    nova_phase1_ok "DynDNS script and units are unchanged; daemon-reload skipped."
  fi
}

nova_phase4b_read_secret() {
  local result_name="$1"
  local local_secrets value

  local_secrets="$(nova_phase1_root_path "/${NOVA_PHASE1_LOCAL_SECRET_RELATIVE_PATH}")"
  value="$(nova_phase1_read_assignment "$local_secrets" DYNDNS_URL || true)"
  printf -v "$result_name" '%s' "$value"
}

nova_phase4b_write_runtime_secret() {
  local value="$1"
  local runtime_dir target temporary_file

  runtime_dir="$(nova_phase1_root_path "/${NOVA_PHASE4B_RUNTIME_DIR_RELATIVE_PATH}")"
  target="$(nova_phase1_root_path "/${NOVA_PHASE4B_RUNTIME_SECRET_RELATIVE_PATH}")"
  if [[ ! -e "$runtime_dir" ]]; then
    mkdir -- "$runtime_dir"
  fi
  chmod 0700 -- "$runtime_dir"
  chown root:root -- "$runtime_dir"

  temporary_file="$(mktemp "${runtime_dir}/.dyndns.env.candidate.XXXXXX")"
  printf 'DYNDNS_URL=%s\n' "$value" > "$temporary_file"
  nova_phase4b_prepare_file "$temporary_file" 0600
  if [[ -f "$target" ]] && cmp -s -- "$temporary_file" "$target"; then
    rm -f -- "$temporary_file"
    nova_phase4b_prepare_file "$target" 0600
    nova_phase1_ok "DynDNS runtime secret is unchanged and remains mode 0600."
  else
    mv -f -- "$temporary_file" "$target"
    nova_phase4b_prepare_file "$target" 0600
    nova_phase1_ok "Updated the root-only DynDNS runtime secret without displaying its value."
  fi
}

nova_phase4b_disable_unresolved() {
  local runtime_secret

  runtime_secret="$(nova_phase1_root_path "/${NOVA_PHASE4B_RUNTIME_SECRET_RELATIVE_PATH}")"
  rm -f -- "$runtime_secret"
  if ! systemctl disable --now dyndns.timer >/dev/null; then
    nova_phase1_error "Could not disable dyndns.timer while DYNDNS_URL is unresolved."
    return 1
  fi
  if ! systemctl stop dyndns.service >/dev/null; then
    nova_phase1_error "Could not stop dyndns.service while DYNDNS_URL is unresolved."
    return 1
  fi
  if systemctl is-enabled --quiet dyndns.timer \
    || systemctl is-active --quiet dyndns.timer; then
    nova_phase1_error "dyndns.timer remained enabled or active with unresolved DYNDNS_URL."
    return 1
  fi
  nova_phase1_warn "DYNDNS_URL is unresolved; DynDNS remains disabled and installation continues."
}

nova_phase4b_activate_and_validate() {
  nova_phase1_info "Running one DynDNS update before enabling the timer."
  systemctl stop dyndns.timer >/dev/null
  if ! systemctl start dyndns.service >/dev/null; then
    systemctl disable --now dyndns.timer >/dev/null 2>&1 || true
    nova_phase1_error "The FreeDNS update failed; dyndns.timer remains disabled."
    return 1
  fi
  if ! systemctl enable --now dyndns.timer >/dev/null; then
    systemctl disable --now dyndns.timer >/dev/null 2>&1 || true
    nova_phase1_error "Could not enable and start dyndns.timer."
    return 1
  fi
  if ! systemctl is-enabled --quiet dyndns.timer; then
    systemctl disable --now dyndns.timer >/dev/null 2>&1 || true
    nova_phase1_error "dyndns.timer is not enabled."
    return 1
  fi
  if ! systemctl is-active --quiet dyndns.timer; then
    systemctl disable --now dyndns.timer >/dev/null 2>&1 || true
    nova_phase1_error "dyndns.timer is not active."
    return 1
  fi
  nova_phase1_ok "One FreeDNS update succeeded; dyndns.timer is enabled and active."
}

nova_phase4b_write_completion_marker() {
  local state_dir marker temporary_file

  state_dir="$(nova_phase1_root_path "/var/lib/nova-infra")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE4B_MARKER_RELATIVE_PATH}")"
  temporary_file="$(mktemp "${state_dir}/.phase4b-complete.XXXXXX")"
  printf '%s\n' 'phase=4b' > "$temporary_file"
  nova_phase4b_prepare_file "$temporary_file" 0644
  if [[ -f "$marker" ]] && cmp -s -- "$temporary_file" "$marker"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$marker"
  fi
}

nova_phase4b_preflight() {
  nova_phase1_info "Phase 4b preflight checks"
  nova_phase4b_require_commands
  nova_phase4b_require_phase4a
  nova_phase4b_check_safe_paths
  nova_phase1_ok "Phase 4b prerequisites are complete; DNS, Unbound, and firewall state remain out of scope."
}

nova_phase4b_main() {
  local dyndns_url=""

  NOVA_PHASE4B_UNITS_CHANGED=0
  nova_phase4b_preflight
  nova_phase4b_validate_script_source
  nova_phase4b_install_file "$NOVA_PHASE4B_SCRIPT_SOURCE" \
    "$(nova_phase1_root_path "/${NOVA_PHASE4B_SCRIPT_RELATIVE_PATH}")" 0755 script
  nova_phase4b_validate_unit_sources
  nova_phase4b_install_managed_files
  nova_phase4b_read_secret dyndns_url
  if [[ -z "$dyndns_url" || "$dyndns_url" == CHANGE_ME_* ]]; then
    nova_phase4b_disable_unresolved
    nova_phase4b_write_completion_marker
    nova_phase1_ok "Phase 4b completed with DynDNS intentionally disabled pending DYNDNS_URL."
    return 0
  fi

  nova_phase4b_write_runtime_secret "$dyndns_url"
  nova_phase4b_activate_and_validate
  nova_phase4b_write_completion_marker
  nova_phase1_ok "Phase 4b completed. FreeDNS DynDNS is managed by the specified oneshot service and hourly timer."
}
