#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_DIR="$(CDPATH= cd -- "${TEST_DIR}/.." && pwd)"
readonly INSTALLER="${REPOSITORY_DIR}/install.sh"
readonly SCRIPT_SOURCE="${REPOSITORY_DIR}/scripts/dyndns-update.sh"
readonly SERVICE_SOURCE="${REPOSITORY_DIR}/systemd/dyndns.service"
readonly TIMER_SOURCE="${REPOSITORY_DIR}/systemd/dyndns.timer"
readonly TEST_SECRET_URL='https://freedns.invalid/dynamic/update.php?token=TEST_SECRET_DYNDNS&mode=direct'
readonly TEST_WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/nova-phase4b-tests.XXXXXX")"

TESTS_RUN=0

cleanup_tests() {
  local original_status=$?
  if [[ "$TEST_WORKSPACE" == "${TMPDIR:-/tmp}"/nova-phase4b-tests.* && -d "$TEST_WORKSPACE" ]]; then
    rm -rf -- "$TEST_WORKSPACE"
  fi
  return "$original_status"
}
trap cleanup_tests EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'ok %d - %s\n' "$TESTS_RUN" "$1"
}

assert_secret_absent() {
  local file="$1"
  local secret="${2:-$TEST_SECRET_URL}"
  ! grep -Fq -- "$secret" "$file" || fail "A secret URL was exposed in ${file}."
  ! grep -Fq -- 'TEST_SECRET_DYNDNS' "$file" || fail "A secret token was exposed in ${file}."
}

new_case() {
  local name="$1"
  local case_dir="${TEST_WORKSPACE}/${name}"
  local command_name mock_name

  mkdir -p -- \
    "${case_dir}/root/opt" \
    "${case_dir}/root/run" \
    "${case_dir}/root/etc/apt/sources.list.d" \
    "${case_dir}/root/etc/systemd/system" \
    "${case_dir}/root/etc/unbound/unbound.conf.d" \
    "${case_dir}/root/proc/device-tree" \
    "${case_dir}/root/usr/libexec" \
    "${case_dir}/root/usr/local/bin" \
    "${case_dir}/root/usr/share/dns" \
    "${case_dir}/root/var/lib/unbound" \
    "${case_dir}/recovery/secrets" \
    "${case_dir}/mock-bin" \
    "${case_dir}/systemctl/active" \
    "${case_dir}/systemctl/enabled" \
    "${case_dir}/systemctl/failed" \
    "${case_dir}/systemctl/masked"
  printf '%s\n' 'ID=debian' 'VERSION_ID="13"' 'VERSION_CODENAME=trixie' \
    > "${case_dir}/root/etc/os-release"
  printf 'Raspberry Pi 5 Model B Rev 1.0\0' > "${case_dir}/root/proc/device-tree/model"
  printf '%s\n' 'nameserver 192.0.2.53' > "${case_dir}/root/etc/resolv.conf"
  printf '%s\n' 'include-toplevel: "/etc/unbound/unbound.conf.d/*.conf"' \
    > "${case_dir}/root/etc/unbound/unbound.conf"
  printf '%s\n' 'server:' '    auto-trust-anchor-file: "/var/lib/unbound/root.key"' \
    > "${case_dir}/root/etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf"
  printf '%s\n' \
    '. 3600000 IN NS A.ROOT-SERVERS.NET.' \
    'A.ROOT-SERVERS.NET. 3600000 IN A 198.41.0.4' \
    > "${case_dir}/root/usr/share/dns/root.hints"
  printf '%s\n' '. IN DS 20326 8 2 TEST-PACKAGED-ROOT-KEY' \
    > "${case_dir}/root/usr/share/dns/root.key"
  printf '%s\n' 'admin sudo' > "${case_dir}/admin.groups"
  : > "${case_dir}/apt.log"
  : > "${case_dir}/operations.log"
  : > "${case_dir}/packages.state"
  : > "${case_dir}/containers.state"
  : > "${case_dir}/phase1-events.log"

  for mock_name in dpkg gpg; do
    cp -- "${REPOSITORY_DIR}/tests/phase2-mocks/${mock_name}" \
      "${case_dir}/mock-bin/${mock_name}"
  done
  for mock_name in apt-cache apt-get dpkg-query getent id usermod; do
    cp -- "${REPOSITORY_DIR}/tests/phase3-mocks/${mock_name}" \
      "${case_dir}/mock-bin/${mock_name}"
  done
  for mock_name in dig ss unbound-checkconf; do
    cp -- "${REPOSITORY_DIR}/tests/phase4a-mocks/${mock_name}" \
      "${case_dir}/mock-bin/${mock_name}"
  done
  for mock_name in curl systemctl systemd-analyze; do
    cp -- "${REPOSITORY_DIR}/tests/phase4b-mocks/${mock_name}" \
      "${case_dir}/mock-bin/${mock_name}"
  done
  cp -- "${REPOSITORY_DIR}/tests/phase4a-mocks/unbound-helper" \
    "${case_dir}/root/usr/libexec/unbound-helper"
  for command_name in ip jq nft ping rsync sudo sysctl unbound unzip wg xz; do
    cp -- "${REPOSITORY_DIR}/tests/phase2-mocks/available-command" \
      "${case_dir}/mock-bin/${command_name}"
  done
  chmod +x -- "${case_dir}/mock-bin/"*
  chmod +x -- "${case_dir}/root/usr/libexec/unbound-helper"
  printf '%s' "$case_dir"
}

write_local_secrets() {
  local case_dir="$1"
  local dyndns_url="$2"
  local file="${case_dir}/root/opt/nova-bootstrap/secrets.env"

  mkdir -p -- "${case_dir}/root/opt/nova-bootstrap"
  printf '%s\n' \
    "DYNDNS_URL=${dyndns_url}" \
    'CAMERA_URL=CHANGE_ME_CAMERA_URL' \
    'TOKEN=CHANGE_ME_TOKEN' \
    'ADGUARD_PASSWORD_HASH=CHANGE_ME_ADGUARD_PASSWORD_HASH' \
    'WG_EASY_PASSWORD=CHANGE_ME_WG_EASY_PASSWORD' > "$file"
  chmod 0600 -- "$file"
}

run_installer() {
  local case_dir="$1"
  local output_file="${case_dir}/output.log"

  NOVA_INSTALL_PHASES=4b \
  NOVA_PHASE1_TEST_MODE=1 \
  NOVA_PHASE1_TEST_ROOT="${case_dir}/root" \
  NOVA_PHASE1_TEST_ARCH=aarch64 \
  NOVA_PHASE1_TEST_EUID=0 \
  NOVA_PHASE1_TEST_NETWORK_OK=1 \
  NOVA_PHASE1_TEST_RECOVERY_SOURCE="" \
  NOVA_PHASE1_TEST_RECOVERY_ALREADY_MOUNTED=0 \
  NOVA_PHASE1_TEST_EVENT_LOG="${case_dir}/phase1-events.log" \
  NOVA_PHASE2_TEST_MODE=1 \
  NOVA_PHASE2_TEST_APT_LOG="${case_dir}/apt.log" \
  NOVA_PHASE2_TEST_OPERATION_LOG="${case_dir}/operations.log" \
  NOVA_PHASE2_TEST_PACKAGE_STATE="${case_dir}/packages.state" \
  NOVA_PHASE2_TEST_SYSTEMCTL_STATE="${case_dir}/systemctl" \
  NOVA_PHASE2_TEST_FAIL_STEP="${NOVA_TEST_PHASE2_FAIL_STEP:-}" \
  NOVA_PHASE2_TEST_MISSING_PACKAGE="" \
  NOVA_PHASE3_TEST_APT_LOG="${case_dir}/apt.log" \
  NOVA_PHASE3_TEST_OPERATION_LOG="${case_dir}/operations.log" \
  NOVA_PHASE3_TEST_PACKAGE_STATE="${case_dir}/packages.state" \
  NOVA_PHASE3_TEST_SYSTEMCTL_STATE="${case_dir}/systemctl" \
  NOVA_PHASE3_TEST_ADMIN_GROUPS="${case_dir}/admin.groups" \
  NOVA_PHASE3_TEST_CONTAINER_STATE="${case_dir}/containers.state" \
  NOVA_PHASE3_TEST_DOCKER_COMMAND_SOURCE="${REPOSITORY_DIR}/tests/phase3-mocks/docker" \
  NOVA_PHASE3_TEST_MOCK_BIN="${case_dir}/mock-bin" \
  NOVA_PHASE3_TEST_REPOSITORY_AVAILABLE="${NOVA_TEST_DOCKER_REPOSITORY_AVAILABLE:-1}" \
  NOVA_PHASE3_TEST_INSTALL_FAIL=0 \
  NOVA_PHASE3_TEST_MISSING_PACKAGE="" \
  NOVA_PHASE3_TEST_ADMIN_PRESENT=1 \
  NOVA_PHASE4A_TEST_MODE=1 \
  NOVA_PHASE4A_TEST_OPERATION_LOG="${case_dir}/operations.log" \
  NOVA_PHASE4A_TEST_SYSTEMCTL_STATE="${case_dir}/systemctl" \
  NOVA_PHASE4A_TEST_PACKAGE_STATE="${case_dir}/packages.state" \
  NOVA_PHASE4A_TEST_MANAGED_CONFIG="${case_dir}/root/etc/unbound/unbound.conf.d/nova.conf" \
  NOVA_PHASE4A_TEST_DNS_ROOT_KEY="${case_dir}/root/usr/share/dns/root.key" \
  NOVA_PHASE4A_TEST_ROOT_KEY="${case_dir}/root/var/lib/unbound/root.key" \
  NOVA_PHASE4A_TEST_CHECKCONF_FAIL="${NOVA_TEST_UNBOUND_CHECKCONF_FAIL:-none}" \
  NOVA_PHASE4A_TEST_PORT53_LISTENER="${NOVA_TEST_UNBOUND_PORT53_LISTENER:-0}" \
  NOVA_PHASE4B_TEST_OPERATION_LOG="${case_dir}/operations.log" \
  NOVA_PHASE4B_TEST_SYSTEMCTL_STATE="${case_dir}/systemctl" \
  NOVA_PHASE4B_TEST_PACKAGE_STATE="${case_dir}/packages.state" \
  NOVA_PHASE4B_TEST_SCRIPT="${case_dir}/root/usr/local/bin/dyndns-update.sh" \
  NOVA_PHASE4B_TEST_EXPECTED_URL="${NOVA_TEST_EXPECTED_URL:-$TEST_SECRET_URL}" \
  NOVA_PHASE4B_TEST_CURL_FAIL="${NOVA_TEST_CURL_FAIL:-0}" \
  NOVA_PHASE4B_TEST_CURL_RESPONSE="${NOVA_TEST_CURL_RESPONSE:-Updated successfully}" \
  NOVA_DYNDNS_CONFIG_FILE="${case_dir}/root/etc/nova-infra/dyndns.env" \
  PATH="${case_dir}/mock-bin:${PATH}" \
    "$INSTALLER" > "$output_file" 2>&1
}

assert_no_phase4b_marker() {
  local case_dir="$1"
  [[ ! -e "${case_dir}/root/var/lib/nova-infra/phase4b-complete" ]] \
    || fail "Failed Phase 4b unexpectedly wrote its completion marker."
}

test_phase_ordering() {
  local case_dir p1 p2 p3 p4a p4b
  case_dir="$(new_case ordering)"
  write_local_secrets "$case_dir" "$TEST_SECRET_URL"
  if ! run_installer "$case_dir"; then
    sed 's/TEST_SECRET_DYNDNS/[REDACTED]/g' "${case_dir}/output.log" >&2
    fail "Valid Phase 4b ordering fixture failed unexpectedly."
  fi
  p1="$(grep -n -m1 'Phase 1 preflight checks' "${case_dir}/output.log")"; p1="${p1%%:*}"
  p2="$(grep -n -m1 'Phase 2 preflight checks' "${case_dir}/output.log")"; p2="${p2%%:*}"
  p3="$(grep -n -m1 'Phase 3 preflight checks' "${case_dir}/output.log")"; p3="${p3%%:*}"
  p4a="$(grep -n -m1 'Phase 4a preflight checks' "${case_dir}/output.log")"; p4a="${p4a%%:*}"
  p4b="$(grep -n -m1 'Phase 4b preflight checks' "${case_dir}/output.log")"; p4b="${p4b%%:*}"
  (( p1 < p2 && p2 < p3 && p3 < p4a && p4a < p4b )) \
    || fail "Installer Phase 4b ordering is incorrect."
  grep -Fxq 'phase=4b' "${case_dir}/root/var/lib/nova-infra/phase4b-complete" \
    || fail "Phase 4b completion marker is missing."
  pass "Phase 4b starts only after successful Phase 1 through Phase 4a"
}

test_phase4a_failure_blocks_phase4b() {
  local case_dir
  case_dir="$(new_case phase4a-failure)"
  write_local_secrets "$case_dir" "$TEST_SECRET_URL"
  NOVA_TEST_UNBOUND_PORT53_LISTENER=1
  if run_installer "$case_dir"; then
    unset NOVA_TEST_UNBOUND_PORT53_LISTENER
    fail "Phase 4a failure unexpectedly allowed Phase 4b to run."
  fi
  unset NOVA_TEST_UNBOUND_PORT53_LISTENER
  ! grep -Fq 'Phase 4b preflight checks' "${case_dir}/output.log" \
    || fail "Phase 4b ran after Phase 4a failed."
  assert_no_phase4b_marker "$case_dir"
  pass "Phase 4a failure prevents Phase 4b"
}

test_valid_secret_runtime_file() {
  local case_dir runtime mode
  case_dir="$(new_case runtime-secret)"
  write_local_secrets "$case_dir" "$TEST_SECRET_URL"
  run_installer "$case_dir"
  runtime="${case_dir}/root/etc/nova-infra/dyndns.env"
  grep -Fxq "DYNDNS_URL=${TEST_SECRET_URL}" "$runtime" \
    || fail "Runtime DynDNS secret does not match the Phase 1 source."
  [[ "$(wc -l < "$runtime" | tr -d ' ')" == "1" ]] \
    || fail "Runtime DynDNS config stores more than the required secret."
  mode="$(stat -c '%a' -- "$runtime")"
  if [[ "$mode" != "600" ]]; then
    grep -Fqx "mode:${runtime}:0600" "${case_dir}/phase1-events.log" \
      || fail "Runtime DynDNS secret mode is not 0600."
  fi
  pass "valid DYNDNS_URL creates a minimal mode-0600 runtime secret"
}

test_unresolved_secret_leaves_disabled() {
  local case_dir
  case_dir="$(new_case unresolved)"
  run_installer "$case_dir"
  [[ ! -e "${case_dir}/root/etc/nova-infra/dyndns.env" ]] \
    || fail "Unresolved DYNDNS_URL left a runtime secret file."
  [[ ! -e "${case_dir}/systemctl/enabled/dyndns.timer" \
    && ! -e "${case_dir}/systemctl/active/dyndns.timer" ]] \
    || fail "Unresolved DYNDNS_URL enabled or started the timer."
  ! grep -Fq 'systemctl:start:dyndns.service' "${case_dir}/operations.log" \
    || fail "Unresolved DYNDNS_URL started the service."
  grep -Fq 'DYNDNS_URL is unresolved; DynDNS remains disabled' "${case_dir}/output.log" \
    || fail "Unresolved secret status was not reported clearly."
  grep -Fxq 'phase=4b' "${case_dir}/root/var/lib/nova-infra/phase4b-complete" \
    || fail "Accepted unresolved-secret state did not complete Phase 4b."
  pass "CHANGE_ME_DYNDNS_URL leaves DynDNS disabled without aborting"
}

test_artifacts_and_schedule() {
  local case_dir service timer script
  case_dir="$(new_case artifacts)"
  write_local_secrets "$case_dir" "$TEST_SECRET_URL"
  run_installer "$case_dir"
  script="${case_dir}/root/usr/local/bin/dyndns-update.sh"
  service="${case_dir}/root/etc/systemd/system/dyndns.service"
  timer="${case_dir}/root/etc/systemd/system/dyndns.timer"
  cmp -s -- "$SCRIPT_SOURCE" "$script" || fail "Installed DynDNS script is not deterministic."
  cmp -s -- "$SERVICE_SOURCE" "$service" || fail "Installed service unit differs from the source."
  cmp -s -- "$TIMER_SOURCE" "$timer" || fail "Installed timer unit differs from the source."
  grep -Fxq 'Type=oneshot' "$service" || fail "DynDNS service is not oneshot."
  grep -Fxq 'After=network-online.target' "$service" || fail "Service lacks network-online ordering."
  grep -Fxq 'ExecStart=/usr/local/bin/dyndns-update.sh' "$service" \
    || fail "Service does not invoke the installed updater script."
  ! grep -Fq 'DYNDNS_URL' "$service" || fail "Service unit embeds the secret variable."
  grep -Fxq 'OnBootSec=2min' "$timer" || fail "Timer OnBootSec differs from the specification."
  grep -Fxq 'OnUnitActiveSec=60min' "$timer" \
    || fail "Timer interval differs from the specification."
  grep -Fxq 'Persistent=true' "$timer" || fail "Timer is not persistent."
  grep -Fxq 'Unit=dyndns.service' "$timer" || fail "Timer does not trigger dyndns.service."
  grep -Fq 'systemd-analyze:verify ' "${case_dir}/operations.log" \
    || fail "systemd unit source validation was not performed."
  pass "service is secret-free and timer schedule exactly matches SPECIFICATION.md"
}

test_successful_update_and_enablement() {
  local case_dir
  case_dir="$(new_case successful-update)"
  write_local_secrets "$case_dir" "$TEST_SECRET_URL"
  NOVA_TEST_CURL_RESPONSE='Current address has not changed'
  run_installer "$case_dir"
  unset NOVA_TEST_CURL_RESPONSE
  [[ -e "${case_dir}/systemctl/enabled/dyndns.timer" \
    && -e "${case_dir}/systemctl/active/dyndns.timer" ]] \
    || fail "Successful update did not enable and activate dyndns.timer."
  [[ "$(grep -c '^systemctl:start:dyndns.service$' "${case_dir}/operations.log")" == "1" ]] \
    || fail "Installer did not invoke exactly one DynDNS update."
  [[ "$(grep -c '^curl:dyndns-update$' "${case_dir}/operations.log")" == "1" ]] \
    || fail "Successful path did not make exactly one FreeDNS request."
  assert_secret_absent "${case_dir}/output.log"
  assert_secret_absent "${case_dir}/operations.log"
  pass "one safe FreeDNS update succeeds and enables the active timer"
}

test_failed_update_is_safe() {
  local case_dir
  case_dir="$(new_case failed-update)"
  write_local_secrets "$case_dir" "$TEST_SECRET_URL"
  NOVA_TEST_CURL_FAIL=1
  if run_installer "$case_dir"; then
    unset NOVA_TEST_CURL_FAIL
    fail "Failed FreeDNS request unexpectedly completed Phase 4b."
  fi
  unset NOVA_TEST_CURL_FAIL
  [[ ! -e "${case_dir}/systemctl/enabled/dyndns.timer" \
    && ! -e "${case_dir}/systemctl/active/dyndns.timer" ]] \
    || fail "Failed update left dyndns.timer enabled or active."
  grep -Fq 'The FreeDNS update failed; dyndns.timer remains disabled' \
    "${case_dir}/output.log" || fail "Failed update was not reported safely."
  assert_secret_absent "${case_dir}/output.log"
  assert_secret_absent "${case_dir}/operations.log"
  assert_no_phase4b_marker "$case_dir"
  pass "curl failure aborts safely without exposing the URL or enabling the timer"
}

test_script_rejects_placeholder() {
  local case_dir config output curl_count_before curl_count_after
  case_dir="$(new_case script-placeholder)"
  write_local_secrets "$case_dir" "$TEST_SECRET_URL"
  run_installer "$case_dir"
  config="${case_dir}/placeholder.env"
  output="${case_dir}/script-output.log"
  printf '%s\n' 'DYNDNS_URL=CHANGE_ME_DYNDNS_URL' > "$config"
  curl_count_before="$(grep -c '^curl:dyndns-update$' "${case_dir}/operations.log")"
  if NOVA_DYNDNS_CONFIG_FILE="$config" PATH="${case_dir}/mock-bin:${PATH}" \
    "${case_dir}/root/usr/local/bin/dyndns-update.sh" > "$output" 2>&1; then
    fail "Updater script accepted CHANGE_ME_DYNDNS_URL."
  fi
  curl_count_after="$(grep -c '^curl:dyndns-update$' "${case_dir}/operations.log")"
  [[ "$curl_count_before" == "$curl_count_after" ]] \
    || fail "Updater called curl with an unresolved placeholder."
  grep -Fq 'DYNDNS_URL is unresolved' "$output" \
    || fail "Updater did not report the unresolved variable safely."
  pass "updater refuses unresolved values before invoking curl"
}

test_repeated_execution_is_idempotent() {
  local case_dir script_hash service_hash timer_hash runtime_hash
  case_dir="$(new_case idempotence)"
  write_local_secrets "$case_dir" "$TEST_SECRET_URL"
  run_installer "$case_dir"
  script_hash="$(sha256sum "${case_dir}/root/usr/local/bin/dyndns-update.sh")"
  service_hash="$(sha256sum "${case_dir}/root/etc/systemd/system/dyndns.service")"
  timer_hash="$(sha256sum "${case_dir}/root/etc/systemd/system/dyndns.timer")"
  runtime_hash="$(sha256sum "${case_dir}/root/etc/nova-infra/dyndns.env")"
  run_installer "$case_dir"
  [[ "$script_hash" == "$(sha256sum "${case_dir}/root/usr/local/bin/dyndns-update.sh")" \
    && "$service_hash" == "$(sha256sum "${case_dir}/root/etc/systemd/system/dyndns.service")" \
    && "$timer_hash" == "$(sha256sum "${case_dir}/root/etc/systemd/system/dyndns.timer")" \
    && "$runtime_hash" == "$(sha256sum "${case_dir}/root/etc/nova-infra/dyndns.env")" ]] \
    || fail "Repeated Phase 4b changed deterministic managed content."
  [[ "$(grep -c '^systemctl:daemon-reload:$' "${case_dir}/operations.log")" == "1" ]] \
    || fail "Repeated unchanged execution reloaded systemd unnecessarily."
  [[ "$(grep -c '^curl:dyndns-update$' "${case_dir}/operations.log")" == "2" ]] \
    || fail "Repeated runs did not perform exactly one validation update per run."
  [[ -e "${case_dir}/systemctl/enabled/dyndns.timer" \
    && -e "${case_dir}/systemctl/active/dyndns.timer" ]] \
    || fail "Repeated execution did not preserve enabled/active timer state."
  pass "repeated Phase 4b preserves files and timer state without duplicate reloads or updates"
}

test_obsolete_installation_is_replaced() {
  local case_dir old_secret='TEST_SECRET_OLD_EMBEDDED_URL'
  case_dir="$(new_case obsolete-installation)"
  write_local_secrets "$case_dir" "$TEST_SECRET_URL"
  printf '#!/bin/sh\ncurl https://freedns.invalid/%s\n' "$old_secret" \
    > "${case_dir}/root/usr/local/bin/dyndns-update.sh"
  printf '[Service]\nEnvironment=DYNDNS_URL=%s\n' "$old_secret" \
    > "${case_dir}/root/etc/systemd/system/dyndns.service"
  printf '[Timer]\nOnCalendar=hourly\n' \
    > "${case_dir}/root/etc/systemd/system/dyndns.timer"
  run_installer "$case_dir"
  cmp -s -- "$SCRIPT_SOURCE" "${case_dir}/root/usr/local/bin/dyndns-update.sh" \
    || fail "Obsolete updater script was not replaced."
  cmp -s -- "$SERVICE_SOURCE" "${case_dir}/root/etc/systemd/system/dyndns.service" \
    || fail "Obsolete service was not replaced."
  cmp -s -- "$TIMER_SOURCE" "${case_dir}/root/etc/systemd/system/dyndns.timer" \
    || fail "Obsolete timer was not replaced."
  assert_secret_absent "${case_dir}/output.log" "$old_secret"
  pass "obsolete DynDNS files are deterministically replaced without exposing old secrets"
}

test_dns_and_firewall_remain_unchanged() {
  local case_dir resolver_before unbound_before
  case_dir="$(new_case no-network-policy-change)"
  write_local_secrets "$case_dir" "$TEST_SECRET_URL"
  resolver_before="$(sha256sum "${case_dir}/root/etc/resolv.conf")"
  unbound_before="$(sha256sum "${case_dir}/root/etc/unbound/unbound.conf")"
  run_installer "$case_dir"
  [[ "$resolver_before" == "$(sha256sum "${case_dir}/root/etc/resolv.conf")" ]] \
    || fail "Phase 4b modified /etc/resolv.conf."
  [[ "$unbound_before" == "$(sha256sum "${case_dir}/root/etc/unbound/unbound.conf")" ]] \
    || fail "Phase 4b modified Debian's Unbound main config."
  ! grep -Eq '^(nft|iptables):' "${case_dir}/operations.log" \
    || fail "Phase 4b changed firewall policy."
  ! grep -Fq ':53' "$SERVICE_SOURCE" \
    || fail "Phase 4b service unexpectedly configures port 53."
  pass "Phase 4b leaves resolver, Unbound, ports, and firewall policy unchanged"
}

printf 'TAP version 13\n'
test_phase_ordering
test_phase4a_failure_blocks_phase4b
test_valid_secret_runtime_file
test_unresolved_secret_leaves_disabled
test_artifacts_and_schedule
test_successful_update_and_enablement
test_failed_update_is_safe
test_script_rejects_placeholder
test_repeated_execution_is_idempotent
test_obsolete_installation_is_replaced
test_dns_and_firewall_remain_unchanged
printf '1..%d\n' "$TESTS_RUN"
