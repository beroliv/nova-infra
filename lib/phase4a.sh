#!/usr/bin/env bash

# Phase 4a only: deterministic configuration and independent validation of the
# Debian-packaged Unbound resolver on TCP/UDP port 5335.

readonly NOVA_PHASE4A_CONFIG_SOURCE="${NOVA_INSTALLER_DIR}/config/unbound/nova.conf"
readonly NOVA_PHASE4A_CONFIG_RELATIVE_PATH="etc/unbound/unbound.conf.d/nova.conf"
readonly NOVA_PHASE4A_MAIN_CONFIG_RELATIVE_PATH="etc/unbound/unbound.conf"
readonly NOVA_PHASE4A_TRUST_ANCHOR_RELATIVE_PATH="etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf"
readonly NOVA_PHASE4A_PACKAGED_ROOT_HINTS_RELATIVE_PATH="usr/share/dns/root.hints"
readonly NOVA_PHASE4A_ROOT_HINTS_RELATIVE_PATH="var/lib/unbound/root.hints"
readonly NOVA_PHASE4A_MARKER_RELATIVE_PATH="var/lib/nova-infra/phase4a-complete"

NOVA_PHASE4A_RESOLVER_FINGERPRINT=""
NOVA_PHASE4A_CONTENT_CHANGED=0
NOVA_PHASE4A_CONFIG_CHANGED=0

nova_phase4a_is_test_mode() {
  [[ "${NOVA_PHASE4A_TEST_MODE:-0}" == "1" ]]
}

nova_phase4a_require_commands() {
  local command_name
  local missing=0
  local -a commands=(cmp cp dig dpkg-query grep mktemp mv rm ss systemctl unbound-checkconf)

  for command_name in "${commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      nova_phase1_error "Required Phase 4a command is missing: ${command_name}"
      missing=1
    fi
  done
  (( missing == 0 ))
}

nova_phase4a_prepare_file() {
  local file="$1"
  local mode="$2"

  chmod "$mode" -- "$file"
  if ! nova_phase4a_is_test_mode; then
    chown root:root -- "$file"
  fi
}

nova_phase4a_require_phase3() {
  local marker
  local status

  marker="$(nova_phase1_root_path "/${NOVA_PHASE3_MARKER_RELATIVE_PATH}")"
  if [[ ! -f "$marker" || -L "$marker" ]] || ! grep -Fxq 'phase=3' "$marker"; then
    nova_phase1_error "Phase 4a requires a successfully completed Phase 3 marker."
    return 1
  fi

  status="$(dpkg-query -W -f='${db:Status-Abbrev}' unbound 2>/dev/null || true)"
  if [[ "$status" != "ii " ]]; then
    nova_phase1_error "Phase 4a requires the Debian unbound package installed by Phase 2."
    return 1
  fi
  nova_phase1_ok "Phase 3 is complete and the Debian unbound package is installed."
}

nova_phase4a_check_safe_paths() {
  local config_dir main_config trust_anchor root_hints_dir packaged_root_hints
  local managed_config marker legacy_file

  config_dir="$(nova_phase1_root_path "/etc/unbound/unbound.conf.d")"
  main_config="$(nova_phase1_root_path "/${NOVA_PHASE4A_MAIN_CONFIG_RELATIVE_PATH}")"
  trust_anchor="$(nova_phase1_root_path "/${NOVA_PHASE4A_TRUST_ANCHOR_RELATIVE_PATH}")"
  root_hints_dir="$(nova_phase1_root_path "/var/lib/unbound")"
  packaged_root_hints="$(nova_phase1_root_path "/${NOVA_PHASE4A_PACKAGED_ROOT_HINTS_RELATIVE_PATH}")"
  managed_config="$(nova_phase1_root_path "/${NOVA_PHASE4A_CONFIG_RELATIVE_PATH}")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE4A_MARKER_RELATIVE_PATH}")"

  nova_phase2_assert_safe_directory "$config_dir" "/etc/unbound/unbound.conf.d"
  nova_phase2_assert_safe_directory "$root_hints_dir" "/var/lib/unbound"
  nova_phase2_assert_safe_file_target "$managed_config" "/etc/unbound/unbound.conf.d/nova.conf"
  nova_phase2_assert_safe_file_target "$(nova_phase1_root_path "/${NOVA_PHASE4A_ROOT_HINTS_RELATIVE_PATH}")" "/var/lib/unbound/root.hints"
  nova_phase2_assert_safe_file_target "$marker" "/var/lib/nova-infra/phase4a-complete"

  for legacy_file in 50-custom.conf 99-modules.conf; do
    legacy_file="${config_dir}/${legacy_file}"
    if [[ -e "$legacy_file" || -L "$legacy_file" ]]; then
      nova_phase1_error "Historical Unbound configuration must be reviewed rather than combined with nova.conf: ${legacy_file}"
      return 1
    fi
  done

  if [[ ! -f "$NOVA_PHASE4A_CONFIG_SOURCE" || -L "$NOVA_PHASE4A_CONFIG_SOURCE" ]]; then
    nova_phase1_error "Repository-managed Unbound configuration source is missing or unsafe."
    return 1
  fi
  if [[ ! -f "$main_config" || -L "$main_config" ]] \
    || ! grep -Eq '^[[:space:]]*include(-toplevel)?:[[:space:]]*"/etc/unbound/unbound\.conf\.d/\*\.conf"' "$main_config"; then
    nova_phase1_error "Debian Unbound main configuration does not safely include /etc/unbound/unbound.conf.d/*.conf."
    return 1
  fi
  if [[ ! -f "$trust_anchor" || -L "$trust_anchor" ]] \
    || ! grep -Eq '^[[:space:]]*auto-trust-anchor-file:' "$trust_anchor"; then
    nova_phase1_error "Debian packaged DNSSEC trust-anchor integration is missing or invalid."
    return 1
  fi
  if [[ ! -s "$packaged_root_hints" || -L "$packaged_root_hints" ]]; then
    nova_phase1_error "Debian packaged root hints are missing or unsafe."
    return 1
  fi
  if ! grep -Eq '^[.][[:space:]]+([0-9]+[[:space:]]+)?(IN[[:space:]]+)?NS[[:space:]]+' "$packaged_root_hints" \
    || ! grep -Eq '^[A-Ma-m]\.ROOT-SERVERS\.NET\.[[:space:]]+([0-9]+[[:space:]]+)?(IN[[:space:]]+)?A[[:space:]]+' "$packaged_root_hints"; then
    nova_phase1_error "Debian packaged root hints do not contain usable root NS and IPv4 address records."
    return 1
  fi
  nova_phase1_ok "Unbound package paths, DNSSEC trust anchor, and root hints passed safety checks."
}

nova_phase4a_install_root_hints() {
  local source target target_dir temporary_file

  source="$(nova_phase1_root_path "/${NOVA_PHASE4A_PACKAGED_ROOT_HINTS_RELATIVE_PATH}")"
  target="$(nova_phase1_root_path "/${NOVA_PHASE4A_ROOT_HINTS_RELATIVE_PATH}")"
  target_dir="$(dirname -- "$target")"
  temporary_file="$(mktemp "${target_dir}/.root.hints.XXXXXX")"

  if ! cp -- "$source" "$temporary_file"; then
    rm -f -- "$temporary_file"
    nova_phase1_error "Could not stage Debian packaged root hints."
    return 1
  fi
  nova_phase4a_prepare_file "$temporary_file" 0644
  if [[ -f "$target" ]] && cmp -s -- "$temporary_file" "$target"; then
    rm -f -- "$temporary_file"
    nova_phase1_ok "Unbound root hints already match the Debian package data."
    return 0
  fi

  if ! mv -f -- "$temporary_file" "$target"; then
    rm -f -- "$temporary_file"
    nova_phase1_error "Could not atomically install Unbound root hints."
    return 1
  fi
  NOVA_PHASE4A_CONTENT_CHANGED=1
  nova_phase1_ok "Installed Unbound root hints from Debian dns-root-data."
}

nova_phase4a_restore_managed_config() {
  local target="$1"
  local backup="$2"
  local had_previous="$3"

  if [[ "$had_previous" == "1" ]]; then
    mv -f -- "$backup" "$target"
  else
    rm -f -- "$target" "$backup"
  fi
}

nova_phase4a_install_managed_config() {
  local target target_dir candidate backup
  local had_previous=0

  target="$(nova_phase1_root_path "/${NOVA_PHASE4A_CONFIG_RELATIVE_PATH}")"
  target_dir="$(dirname -- "$target")"
  candidate="$(mktemp "${target_dir}/.nova.conf.candidate.XXXXXX")"
  backup="$(mktemp "${target_dir}/.nova.conf.backup.XXXXXX")"

  if ! cp -- "$NOVA_PHASE4A_CONFIG_SOURCE" "$candidate"; then
    rm -f -- "$candidate" "$backup"
    nova_phase1_error "Could not stage nova.conf."
    return 1
  fi
  nova_phase4a_prepare_file "$candidate" 0644

  nova_phase1_info "Validating the staged nova.conf before installation."
  if ! unbound-checkconf "$candidate" >/dev/null; then
    rm -f -- "$candidate" "$backup"
    nova_phase1_error "Staged nova.conf failed unbound-checkconf; the installed configuration was not changed."
    return 1
  fi

  if [[ -f "$target" ]] && cmp -s -- "$candidate" "$target"; then
    rm -f -- "$candidate" "$backup"
    nova_phase1_info "nova.conf is unchanged; no service restart will be requested for configuration content."
  else
    if [[ -f "$target" ]]; then
      had_previous=1
      if ! cp -- "$target" "$backup"; then
        rm -f -- "$candidate" "$backup"
        nova_phase1_error "Could not create a temporary rollback copy of the existing nova.conf."
        return 1
      fi
      nova_phase4a_prepare_file "$backup" 0644
    fi
    if ! mv -f -- "$candidate" "$target"; then
      rm -f -- "$candidate" "$backup"
      nova_phase1_error "Could not atomically install nova.conf."
      return 1
    fi
    NOVA_PHASE4A_CONTENT_CHANGED=1
    NOVA_PHASE4A_CONFIG_CHANGED=1
  fi

  nova_phase1_info "Validating the complete Debian Unbound configuration before service activation."
  if ! unbound-checkconf >/dev/null; then
    if (( NOVA_PHASE4A_CONFIG_CHANGED == 1 )); then
      if ! nova_phase4a_restore_managed_config "$target" "$backup" "$had_previous"; then
        nova_phase1_error "Complete validation failed and the previous nova.conf could not be restored safely."
        return 1
      fi
    else
      rm -f -- "$backup"
    fi
    nova_phase1_error "Complete Unbound configuration validation failed; the previous nova.conf was restored."
    return 1
  fi
  rm -f -- "$backup"
  nova_phase1_ok "Staged and complete Unbound configuration validation succeeded."
}

nova_phase4a_activate_service() {
  if ! systemctl enable unbound.service >/dev/null; then
    nova_phase1_error "Could not enable unbound.service."
    return 1
  fi

  if (( NOVA_PHASE4A_CONTENT_CHANGED == 1 )); then
    nova_phase1_info "Unbound content changed; restarting the validated service configuration."
    if ! systemctl restart unbound.service >/dev/null; then
      nova_phase1_error "Could not restart unbound.service with the validated configuration."
      return 1
    fi
  elif ! systemctl is-active --quiet unbound.service; then
    nova_phase1_info "Unbound configuration is unchanged but the service is inactive; starting it."
    if ! systemctl start unbound.service >/dev/null; then
      nova_phase1_error "Could not start unbound.service."
      return 1
    fi
  else
    nova_phase1_ok "Unbound configuration and active service state are unchanged; restart skipped."
  fi
}

nova_phase4a_verify_service_and_ports() {
  local listeners unbound_listeners

  if [[ "$(nova_phase2_read_unit_state is-enabled unbound.service)" != "enabled" ]]; then
    nova_phase1_error "unbound.service is not enabled."
    return 1
  fi
  if ! systemctl is-active --quiet unbound.service; then
    nova_phase1_error "unbound.service is not active."
    return 1
  fi

  listeners="$(ss -H -lntup)"
  unbound_listeners="$(grep -F 'unbound' <<< "$listeners" || true)"
  if [[ -z "$unbound_listeners" ]]; then
    nova_phase1_error "No Unbound listener was found."
    return 1
  fi
  if ! grep -Eq '^udp[[:space:]].*:5335([[:space:]]|$)' <<< "$unbound_listeners" \
    || ! grep -Eq '^tcp[[:space:]].*:5335([[:space:]]|$)' <<< "$unbound_listeners"; then
    nova_phase1_error "Unbound is not listening on both UDP and TCP port 5335."
    return 1
  fi
  if grep -Eq ':53([[:space:]]|$)' <<< "$unbound_listeners"; then
    nova_phase1_error "Unbound unexpectedly listens on port 53."
    return 1
  fi
  nova_phase1_ok "unbound.service is enabled and active on UDP/TCP 5335 without a port-53 listener."
}

nova_phase4a_query() {
  local domain="$1"
  local record_type="$2"

  dig @127.0.0.1 -p 5335 "$domain" "$record_type" +dnssec +time=5 +tries=2
}

nova_phase4a_verify_resolver() {
  local result first_answer second_answer

  nova_phase1_info "Validating Unbound directly on 127.0.0.1:5335 without AdGuard."
  if ! first_answer="$(nova_phase4a_query example.com A)" \
    || ! grep -Eq 'status: NOERROR' <<< "$first_answer" \
    || ! grep -Eq 'ANSWER: [1-9][0-9]*' <<< "$first_answer"; then
    nova_phase1_error "Direct public A-record resolution through Unbound failed."
    return 1
  fi
  if ! second_answer="$(nova_phase4a_query example.com A)" \
    || ! grep -Eq 'status: NOERROR' <<< "$second_answer" \
    || ! grep -Eq 'ANSWER: [1-9][0-9]*' <<< "$second_answer"; then
    nova_phase1_error "Repeated direct resolution through Unbound failed."
    return 1
  fi

  if ! result="$(nova_phase4a_query cloudflare.com A)" \
    || ! grep -Eq 'status: NOERROR' <<< "$result" \
    || ! grep -Eq 'flags:.*[[:space:]]ad[;[:space:]]' <<< "$result"; then
    nova_phase1_error "DNSSEC-valid resolution through Unbound did not return authenticated data."
    return 1
  fi

  result="$(nova_phase4a_query dnssec-failed.org A 2>&1 || true)"
  if ! grep -Eq 'status: SERVFAIL' <<< "$result"; then
    nova_phase1_error "The stable DNSSEC-broken test domain did not fail with SERVFAIL."
    return 1
  fi
  nova_phase1_ok "Direct, repeated, DNSSEC-valid, and DNSSEC-broken resolver checks passed."
}

nova_phase4a_verify_resolver_file_unchanged() {
  local resolver_file current_fingerprint

  resolver_file="$(nova_phase1_root_path "/etc/resolv.conf")"
  current_fingerprint="$(nova_phase2_file_fingerprint "$resolver_file")"
  if [[ "$current_fingerprint" != "$NOVA_PHASE4A_RESOLVER_FINGERPRINT" ]]; then
    nova_phase1_error "/etc/resolv.conf changed during Phase 4a; refusing to continue."
    return 1
  fi
  nova_phase1_ok "/etc/resolv.conf is unchanged; the host resolver was not switched."
}

nova_phase4a_write_completion_marker() {
  local state_dir marker temporary_file

  state_dir="$(nova_phase1_root_path "/var/lib/nova-infra")"
  marker="$(nova_phase1_root_path "/${NOVA_PHASE4A_MARKER_RELATIVE_PATH}")"
  temporary_file="$(mktemp "${state_dir}/.phase4a-complete.XXXXXX")"
  printf '%s\n' 'phase=4a' > "$temporary_file"
  nova_phase4a_prepare_file "$temporary_file" 0644
  if [[ -f "$marker" ]] && cmp -s -- "$temporary_file" "$marker"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$marker"
  fi
}

nova_phase4a_preflight() {
  local resolver_file

  nova_phase1_info "Phase 4a preflight checks"
  nova_phase4a_require_commands
  nova_phase4a_require_phase3
  nova_phase4a_check_safe_paths
  resolver_file="$(nova_phase1_root_path "/etc/resolv.conf")"
  NOVA_PHASE4A_RESOLVER_FINGERPRINT="$(nova_phase2_file_fingerprint "$resolver_file")"
  nova_phase1_ok "Phase 4a prerequisites are complete; no DNS or firewall transition was performed."
}

nova_phase4a_main() {
  NOVA_PHASE4A_CONTENT_CHANGED=0
  NOVA_PHASE4A_CONFIG_CHANGED=0
  nova_phase4a_preflight
  nova_phase4a_install_root_hints
  nova_phase4a_install_managed_config
  nova_phase4a_activate_service
  nova_phase1_info "Checking Unbound service ownership and listener ports."
  nova_phase4a_verify_service_and_ports
  nova_phase4a_verify_resolver
  nova_phase4a_verify_resolver_file_unchanged
  nova_phase4a_write_completion_marker
  nova_phase1_ok "Phase 4a completed. Unbound is independently available on port 5335; no later service was configured."
}
