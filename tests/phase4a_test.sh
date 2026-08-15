#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_DIR="$(CDPATH= cd -- "${TEST_DIR}/.." && pwd)"
readonly INSTALLER="${REPOSITORY_DIR}/install.sh"
readonly CONFIG_SOURCE="${REPOSITORY_DIR}/config/unbound/nova.conf"
readonly TEST_WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/nova-phase4a-tests.XXXXXX")"

TESTS_RUN=0

cleanup_tests() {
  local original_status=$?
  if [[ "$TEST_WORKSPACE" == "${TMPDIR:-/tmp}"/nova-phase4a-tests.* && -d "$TEST_WORKSPACE" ]]; then
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

new_case() {
  local name="$1"
  local case_dir="${TEST_WORKSPACE}/${name}"
  local command_name mock_name

  mkdir -p -- \
    "${case_dir}/root/opt" \
    "${case_dir}/root/run" \
    "${case_dir}/root/etc/apt/sources.list.d" \
    "${case_dir}/root/etc/unbound/unbound.conf.d" \
    "${case_dir}/root/proc/device-tree" \
    "${case_dir}/root/usr/share/dns" \
    "${case_dir}/root/var/lib/unbound" \
    "${case_dir}/recovery/secrets" \
    "${case_dir}/mock-bin" \
    "${case_dir}/systemctl/active" \
    "${case_dir}/systemctl/enabled" \
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
  printf '%s\n' 'admin sudo' > "${case_dir}/admin.groups"
  : > "${case_dir}/apt.log"
  : > "${case_dir}/operations.log"
  : > "${case_dir}/packages.state"
  : > "${case_dir}/containers.state"
  : > "${case_dir}/phase1-events.log"

  for mock_name in curl dpkg gpg; do
    cp -- "${REPOSITORY_DIR}/tests/phase2-mocks/${mock_name}" \
      "${case_dir}/mock-bin/${mock_name}"
  done
  for mock_name in apt-cache apt-get dpkg-query getent id usermod; do
    cp -- "${REPOSITORY_DIR}/tests/phase3-mocks/${mock_name}" \
      "${case_dir}/mock-bin/${mock_name}"
  done
  for mock_name in dig ss systemctl unbound-checkconf; do
    cp -- "${REPOSITORY_DIR}/tests/phase4a-mocks/${mock_name}" \
      "${case_dir}/mock-bin/${mock_name}"
  done
  for command_name in ip jq nft ping rsync sudo sysctl unbound unzip wg xz; do
    cp -- "${REPOSITORY_DIR}/tests/phase2-mocks/available-command" \
      "${case_dir}/mock-bin/${command_name}"
  done
  chmod +x -- "${case_dir}/mock-bin/"*
  printf '%s' "$case_dir"
}

run_installer() {
  local case_dir="$1"
  local output_file="${case_dir}/output.log"

  NOVA_INSTALL_PHASES=4a \
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
  NOVA_PHASE4A_TEST_CHECKCONF_FAIL="${NOVA_TEST_UNBOUND_CHECKCONF_FAIL:-none}" \
  NOVA_PHASE4A_TEST_PORT53_LISTENER="${NOVA_TEST_UNBOUND_PORT53_LISTENER:-0}" \
  PATH="${case_dir}/mock-bin:${PATH}" \
    "$INSTALLER" > "$output_file" 2>&1
}

assert_no_phase4a_marker() {
  local case_dir="$1"
  [[ ! -e "${case_dir}/root/var/lib/nova-infra/phase4a-complete" ]] \
    || fail "Failed Phase 4a unexpectedly wrote its completion marker."
}

test_phase_ordering_and_prerequisites() {
  local case_dir phase1_line phase2_line phase3_line phase4a_line
  case_dir="$(new_case ordering)"
  run_installer "$case_dir"
  phase1_line="$(grep -n -m1 'Phase 1 preflight checks' "${case_dir}/output.log")"
  phase2_line="$(grep -n -m1 'Phase 2 preflight checks' "${case_dir}/output.log")"
  phase3_line="$(grep -n -m1 'Phase 3 preflight checks' "${case_dir}/output.log")"
  phase4a_line="$(grep -n -m1 'Phase 4a preflight checks' "${case_dir}/output.log")"
  phase1_line="${phase1_line%%:*}"
  phase2_line="${phase2_line%%:*}"
  phase3_line="${phase3_line%%:*}"
  phase4a_line="${phase4a_line%%:*}"
  (( phase1_line < phase2_line && phase2_line < phase3_line && phase3_line < phase4a_line )) \
    || fail "Installer Phase 4a ordering is incorrect."
  grep -Fxq 'phase=3' "${case_dir}/root/var/lib/nova-infra/phase3-complete" \
    || fail "Phase 3 marker was unavailable before Phase 4a."
  grep -Fxq 'phase=4a' "${case_dir}/root/var/lib/nova-infra/phase4a-complete" \
    || fail "Phase 4a completion marker is missing."
  pass "Phase 4a starts only after successful Phase 1, Phase 2, and Phase 3"
}

test_phase3_failure_blocks_phase4a() {
  local case_dir
  case_dir="$(new_case phase3-failure)"
  NOVA_TEST_DOCKER_REPOSITORY_AVAILABLE=0
  if run_installer "$case_dir"; then
    unset NOVA_TEST_DOCKER_REPOSITORY_AVAILABLE
    fail "Phase 3 failure unexpectedly allowed Phase 4a to run."
  fi
  unset NOVA_TEST_DOCKER_REPOSITORY_AVAILABLE
  ! grep -Fq 'Phase 4a preflight checks' "${case_dir}/output.log" \
    || fail "Phase 4a ran after Phase 3 failed."
  assert_no_phase4a_marker "$case_dir"
  pass "Phase 3 failure prevents Phase 4a"
}

test_exact_managed_configuration() {
  local case_dir config setting network
  case_dir="$(new_case exact-config)"
  run_installer "$case_dir"
  config="${case_dir}/root/etc/unbound/unbound.conf.d/nova.conf"

  cmp -s -- "$CONFIG_SOURCE" "$config" \
    || fail "Installed nova.conf does not exactly match the repository configuration."
  [[ "$(grep -c '^server:$' "$config")" == "1" ]] \
    || fail "nova.conf contains duplicate server blocks."
  grep -Eq '^[[:space:]]*port:[[:space:]]*5335$' "$config" \
    || fail "nova.conf does not configure port 5335."
  ! grep -Eq '^[[:space:]]*port:[[:space:]]*53$' "$config" \
    || fail "nova.conf configures prohibited port 53."
  grep -Eq '^[[:space:]]*do-ip6:[[:space:]]*no$' "$config" \
    || fail "nova.conf does not disable IPv6."
  ! grep -Eq '^[[:space:]]*pidfile:' "$config" \
    || fail "nova.conf contains a prohibited pidfile directive."
  ! grep -Eq '^[[:space:]]*auto-trust-anchor-file:' "$config" \
    || fail "nova.conf duplicates Debian DNSSEC trust-anchor configuration."

  for network in 127.0.0.0/8 10.0.0.0/8 192.168.0.0/16 10.8.0.0/16; do
    grep -Fq "access-control: ${network} allow" "$config" \
      || fail "nova.conf is missing access-control for ${network}."
  done
  for setting in \
    'chroot: ""' 'verbosity: 1' 'interface: 0.0.0.0' \
    'hide-identity: yes' 'hide-version: yes' \
    'harden-algo-downgrade: yes' 'harden-referral-path: yes' \
    'harden-glue: yes' 'harden-dnssec-stripped: yes' \
    'harden-below-nxdomain: yes' 'qname-minimisation: yes' \
    'aggressive-nsec: yes' 'cache-min-ttl: 3600' \
    'cache-max-ttl: 86400' 'prefetch: yes' 'prefetch-key: yes' \
    'serve-expired: yes' 'serve-expired-ttl: 172800' \
    'serve-expired-client-timeout: 1800' 'serve-expired-reply-ttl: 30' \
    'msg-cache-size: 128m' 'rrset-cache-size: 256m'; do
    grep -Fq "$setting" "$config" || fail "nova.conf is missing setting: ${setting}"
  done
  pass "exact single nova.conf contains the required port, access, hardening, DNSSEC, and cache settings"
}

test_packaged_root_hints_and_dnssec_anchor() {
  local case_dir anchor anchor_before
  case_dir="$(new_case packaged-dns-data)"
  anchor="${case_dir}/root/etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf"
  anchor_before="$(sha256sum "$anchor")"
  run_installer "$case_dir"
  cmp -s -- "${case_dir}/root/usr/share/dns/root.hints" \
    "${case_dir}/root/var/lib/unbound/root.hints" \
    || fail "Installed root hints do not match Debian dns-root-data."
  [[ "$anchor_before" == "$(sha256sum "$anchor")" ]] \
    || fail "Phase 4a modified Debian's packaged DNSSEC trust-anchor include."
  pass "root hints come from Debian package data and packaged DNSSEC integration remains unchanged"
}

test_resolver_and_later_services_remain_untouched() {
  local case_dir resolver_before
  case_dir="$(new_case no-dns-transition)"
  resolver_before="$(sha256sum "${case_dir}/root/etc/resolv.conf")"
  run_installer "$case_dir"
  [[ "$resolver_before" == "$(sha256sum "${case_dir}/root/etc/resolv.conf")" ]] \
    || fail "Phase 4a modified /etc/resolv.conf."
  [[ ! -e "${case_dir}/root/opt/AdGuardHome" ]] \
    || fail "Phase 4a configured AdGuard Home."
  ! grep -Eq '^(nft|iptables):' "${case_dir}/operations.log" \
    || fail "Phase 4a changed firewall policy."
  pass "Phase 4a leaves host DNS, AdGuard, and firewall policy untouched"
}

test_checkconf_precedes_activation() {
  local case_dir candidate_line complete_line enable_line restart_line
  case_dir="$(new_case validation-order)"
  run_installer "$case_dir"
  candidate_line="$(grep -n -m1 '^unbound-checkconf:.*\.nova\.conf\.candidate\.' "${case_dir}/operations.log")"
  complete_line="$(grep -n -m1 '^unbound-checkconf:$' "${case_dir}/operations.log")"
  enable_line="$(grep -n -m1 '^systemctl:enable:unbound.service$' "${case_dir}/operations.log")"
  restart_line="$(grep -n -m1 '^systemctl:restart:unbound.service$' "${case_dir}/operations.log")"
  candidate_line="${candidate_line%%:*}"
  complete_line="${complete_line%%:*}"
  enable_line="${enable_line%%:*}"
  restart_line="${restart_line%%:*}"
  (( candidate_line < complete_line && complete_line < enable_line && enable_line < restart_line )) \
    || fail "unbound-checkconf did not precede service activation/restart."
  pass "staged and complete unbound-checkconf validation precedes service activation"
}

test_invalid_candidate_aborts_safely() {
  local case_dir config config_before
  case_dir="$(new_case invalid-candidate)"
  config="${case_dir}/root/etc/unbound/unbound.conf.d/nova.conf"
  printf '%s\n' 'server:' '    port: 5999' > "$config"
  config_before="$(sha256sum "$config")"
  NOVA_TEST_UNBOUND_CHECKCONF_FAIL=candidate
  if run_installer "$case_dir"; then
    unset NOVA_TEST_UNBOUND_CHECKCONF_FAIL
    fail "Invalid staged configuration unexpectedly succeeded."
  fi
  unset NOVA_TEST_UNBOUND_CHECKCONF_FAIL
  [[ "$config_before" == "$(sha256sum "$config")" ]] \
    || fail "Invalid staged configuration replaced the existing nova.conf."
  ! grep -q '^systemctl:enable:unbound.service$' "${case_dir}/operations.log" \
    || fail "Unbound was enabled after staged configuration validation failed."
  assert_no_phase4a_marker "$case_dir"
  pass "invalid staged configuration aborts without replacing or activating nova.conf"
}

test_complete_validation_rolls_back() {
  local case_dir config config_before
  case_dir="$(new_case complete-validation-failure)"
  config="${case_dir}/root/etc/unbound/unbound.conf.d/nova.conf"
  printf '%s\n' 'server:' '    port: 5999' > "$config"
  config_before="$(sha256sum "$config")"
  NOVA_TEST_UNBOUND_CHECKCONF_FAIL=complete
  if run_installer "$case_dir"; then
    unset NOVA_TEST_UNBOUND_CHECKCONF_FAIL
    fail "Invalid complete configuration unexpectedly succeeded."
  fi
  unset NOVA_TEST_UNBOUND_CHECKCONF_FAIL
  [[ "$config_before" == "$(sha256sum "$config")" ]] \
    || fail "Complete validation failure did not restore the previous nova.conf."
  ! grep -q '^systemctl:enable:unbound.service$' "${case_dir}/operations.log" \
    || fail "Unbound was enabled after complete validation failed."
  assert_no_phase4a_marker "$case_dir"
  pass "complete configuration failure restores the previous nova.conf before activation"
}

test_service_ports_and_direct_queries() {
  local case_dir
  case_dir="$(new_case service-and-resolver)"
  run_installer "$case_dir"
  [[ -e "${case_dir}/systemctl/enabled/unbound.service" \
    && -e "${case_dir}/systemctl/active/unbound.service" ]] \
    || fail "unbound.service is not enabled and active."
  grep -Fq 'ss:-H -lntup' "${case_dir}/operations.log" \
    || fail "Unbound listener ports were not inspected."
  [[ "$(grep -c '^dig:@127.0.0.1 -p 5335 example.com A ' "${case_dir}/operations.log")" == "2" ]] \
    || fail "Normal public A resolution was not tested twice directly."
  grep -Fq 'dig:@127.0.0.1 -p 5335 cloudflare.com A +dnssec' "${case_dir}/operations.log" \
    || fail "DNSSEC-valid direct query was not performed."
  grep -Fq 'dig:@127.0.0.1 -p 5335 dnssec-failed.org A +dnssec' "${case_dir}/operations.log" \
    || fail "DNSSEC-broken direct query was not performed."
  pass "Unbound is enabled and active on 5335 and passes independent direct resolver checks"
}

test_port53_listener_is_rejected() {
  local case_dir
  case_dir="$(new_case reject-port53)"
  NOVA_TEST_UNBOUND_PORT53_LISTENER=1
  if run_installer "$case_dir"; then
    unset NOVA_TEST_UNBOUND_PORT53_LISTENER
    fail "Unexpected Unbound port-53 listener was accepted."
  fi
  unset NOVA_TEST_UNBOUND_PORT53_LISTENER
  grep -Fq 'Unbound unexpectedly listens on port 53' "${case_dir}/output.log" \
    || fail "Port-53 listener failure was not reported clearly."
  assert_no_phase4a_marker "$case_dir"
  pass "runtime validation rejects an Unbound listener on port 53"
}

test_repeated_execution_is_idempotent() {
  local case_dir config_hash hints_hash
  case_dir="$(new_case idempotence)"
  run_installer "$case_dir"
  config_hash="$(sha256sum "${case_dir}/root/etc/unbound/unbound.conf.d/nova.conf")"
  hints_hash="$(sha256sum "${case_dir}/root/var/lib/unbound/root.hints")"
  run_installer "$case_dir"
  [[ "$config_hash" == "$(sha256sum "${case_dir}/root/etc/unbound/unbound.conf.d/nova.conf")" ]] \
    || fail "Repeated Phase 4a changed deterministic nova.conf content."
  [[ "$hints_hash" == "$(sha256sum "${case_dir}/root/var/lib/unbound/root.hints")" ]] \
    || fail "Repeated Phase 4a changed identical Debian root hints."
  [[ "$(grep -c '^systemctl:restart:unbound.service$' "${case_dir}/operations.log")" == "1" ]] \
    || fail "Repeated Phase 4a restarted unchanged Unbound unnecessarily."
  [[ -e "${case_dir}/systemctl/enabled/unbound.service" \
    && -e "${case_dir}/systemctl/active/unbound.service" ]] \
    || fail "Repeated Phase 4a did not preserve enabled/active Unbound ownership."
  pass "repeated Phase 4a is deterministic, skips unnecessary restart, and preserves service ownership"
}

printf 'TAP version 13\n'
test_phase_ordering_and_prerequisites
test_phase3_failure_blocks_phase4a
test_exact_managed_configuration
test_packaged_root_hints_and_dnssec_anchor
test_resolver_and_later_services_remain_untouched
test_checkconf_precedes_activation
test_invalid_candidate_aborts_safely
test_complete_validation_rolls_back
test_service_ports_and_direct_queries
test_port53_listener_is_rejected
test_repeated_execution_is_idempotent
printf '1..%d\n' "$TESTS_RUN"
