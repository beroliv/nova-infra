#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_DIR="$(CDPATH= cd -- "${TEST_DIR}/.." && pwd)"
readonly INSTALLER="${REPOSITORY_DIR}/install.sh"
readonly COMPOSE_SOURCE="${REPOSITORY_DIR}/compose/wg-easy/compose.yml"
readonly INIT_SOURCE="${REPOSITORY_DIR}/compose/wg-easy/compose.init.yml"
readonly TEST_SECRET_URL='https://freedns.invalid/update?token=TEST_SECRET_DYNDNS'
readonly TEST_SECRET_PASSWORD='TEST_SECRET_WG_EASY;$HOME&`not-executed`'
readonly TEST_WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/nova-phase4c-tests.XXXXXX")"

TESTS_RUN=0

cleanup_tests() {
  local original_status=$?
  if [[ "$TEST_WORKSPACE" == "${TMPDIR:-/tmp}"/nova-phase4c-tests.* && -d "$TEST_WORKSPACE" ]]; then
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

count_lines() {
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -l < "$file" | tr -d ' '
  else
    printf '0'
  fi
}

assert_secret_absent() {
  local file="$1"
  ! grep -Fq -- "$TEST_SECRET_PASSWORD" "$file" \
    || fail "WG_EASY_PASSWORD was exposed in ${file}."
  ! grep -Fq -- 'TEST_SECRET_WG_EASY' "$file" \
    || fail "WG_EASY_PASSWORD marker was exposed in ${file}."
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
    "${case_dir}/docker-state" \
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
  local password="$2"
  local file="${case_dir}/root/opt/nova-bootstrap/secrets.env"

  mkdir -p -- "${case_dir}/root/opt/nova-bootstrap"
  printf '%s\n' \
    "DYNDNS_URL=${TEST_SECRET_URL}" \
    'CAMERA_URL=CHANGE_ME_CAMERA_URL' \
    'TOKEN=CHANGE_ME_TOKEN' \
    'ADGUARD_PASSWORD_HASH=CHANGE_ME_ADGUARD_PASSWORD_HASH' \
    "WG_EASY_PASSWORD=${password}" > "$file"
  chmod 0600 -- "$file"
}

run_installer() {
  local case_dir="$1"
  local output_file="${case_dir}/output.log"

  NOVA_INSTALL_PHASES=4c \
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
  NOVA_PHASE2_TEST_FAIL_STEP="" \
  NOVA_PHASE2_TEST_MISSING_PACKAGE="" \
  NOVA_PHASE3_TEST_APT_LOG="${case_dir}/apt.log" \
  NOVA_PHASE3_TEST_OPERATION_LOG="${case_dir}/operations.log" \
  NOVA_PHASE3_TEST_PACKAGE_STATE="${case_dir}/packages.state" \
  NOVA_PHASE3_TEST_SYSTEMCTL_STATE="${case_dir}/systemctl" \
  NOVA_PHASE3_TEST_ADMIN_GROUPS="${case_dir}/admin.groups" \
  NOVA_PHASE3_TEST_CONTAINER_STATE="${case_dir}/containers.state" \
  NOVA_PHASE3_TEST_DOCKER_COMMAND_SOURCE="${REPOSITORY_DIR}/tests/phase4c-mocks/docker" \
  NOVA_PHASE3_TEST_MOCK_BIN="${case_dir}/mock-bin" \
  NOVA_PHASE3_TEST_REPOSITORY_AVAILABLE=1 \
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
  NOVA_PHASE4A_TEST_CHECKCONF_FAIL=none \
  NOVA_PHASE4A_TEST_PORT53_LISTENER=0 \
  NOVA_PHASE4B_TEST_OPERATION_LOG="${case_dir}/operations.log" \
  NOVA_PHASE4B_TEST_SYSTEMCTL_STATE="${case_dir}/systemctl" \
  NOVA_PHASE4B_TEST_PACKAGE_STATE="${case_dir}/packages.state" \
  NOVA_PHASE4B_TEST_SCRIPT="${case_dir}/root/usr/local/bin/dyndns-update.sh" \
  NOVA_PHASE4B_TEST_EXPECTED_URL="$TEST_SECRET_URL" \
  NOVA_PHASE4B_TEST_CURL_FAIL="${NOVA_TEST_CURL_FAIL:-0}" \
  NOVA_PHASE4B_TEST_CURL_RESPONSE='Updated successfully' \
  NOVA_DYNDNS_CONFIG_FILE="${case_dir}/root/etc/nova-infra/dyndns.env" \
  NOVA_PHASE4C_TEST_OPERATION_LOG="${case_dir}/operations.log" \
  NOVA_PHASE4C_TEST_STATE_DIR="${case_dir}/docker-state" \
  NOVA_PHASE4C_TEST_DATA_DIR="${case_dir}/root/opt/wg-easy/data" \
  NOVA_PHASE4C_TEST_EXPECTED_PASSWORD="${NOVA_TEST_EXPECTED_PASSWORD:-$TEST_SECRET_PASSWORD}" \
  NOVA_PHASE4C_TEST_FAIL_STEP="${NOVA_TEST_PHASE4C_FAIL_STEP:-}" \
  NOVA_PHASE4C_TEST_PUBLIC_UI="${NOVA_TEST_PUBLIC_UI:-0}" \
  NOVA_PHASE4C_TEST_COMPOSE_PROJECT="${NOVA_TEST_COMPOSE_PROJECT:-wg-easy}" \
  NOVA_PHASE4C_TEST_PREEXISTING_CONTAINER="${NOVA_TEST_PREEXISTING_CONTAINER:-0}" \
  PATH="${case_dir}/mock-bin:${PATH}" \
    "$INSTALLER" > "$output_file" 2>&1
}

assert_no_phase4c_marker() {
  local case_dir="$1"
  [[ ! -e "${case_dir}/root/var/lib/nova-infra/phase4c-complete" ]] \
    || fail "Failed Phase 4c unexpectedly wrote its completion marker."
}

test_phase_ordering() {
  local case_dir p1 p2 p3 p4a p4b p4c
  case_dir="$(new_case ordering)"
  write_local_secrets "$case_dir" "$TEST_SECRET_PASSWORD"
  run_installer "$case_dir"
  p1="$(grep -n -m1 'Phase 1 preflight checks' "${case_dir}/output.log")"; p1="${p1%%:*}"
  p2="$(grep -n -m1 'Phase 2 preflight checks' "${case_dir}/output.log")"; p2="${p2%%:*}"
  p3="$(grep -n -m1 'Phase 3 preflight checks' "${case_dir}/output.log")"; p3="${p3%%:*}"
  p4a="$(grep -n -m1 'Phase 4a preflight checks' "${case_dir}/output.log")"; p4a="${p4a%%:*}"
  p4b="$(grep -n -m1 'Phase 4b preflight checks' "${case_dir}/output.log")"; p4b="${p4b%%:*}"
  p4c="$(grep -n -m1 'Phase 4c preflight checks' "${case_dir}/output.log")"; p4c="${p4c%%:*}"
  (( p1 < p2 && p2 < p3 && p3 < p4a && p4a < p4b && p4b < p4c )) \
    || fail "Installer Phase 4c ordering is incorrect."
  grep -Fxq 'phase=4c' "${case_dir}/root/var/lib/nova-infra/phase4c-complete" \
    || fail "Phase 4c completion marker is missing."
  pass "Phase 4c starts only after successful Phase 1 through Phase 4b"
}

test_phase4b_failure_blocks_phase4c() {
  local case_dir
  case_dir="$(new_case phase4b-failure)"
  write_local_secrets "$case_dir" "$TEST_SECRET_PASSWORD"
  NOVA_TEST_CURL_FAIL=1
  if run_installer "$case_dir"; then
    unset NOVA_TEST_CURL_FAIL
    fail "Phase 4b failure unexpectedly allowed Phase 4c to run."
  fi
  unset NOVA_TEST_CURL_FAIL
  ! grep -Fq 'Phase 4c preflight checks' "${case_dir}/output.log" \
    || fail "Phase 4c ran after Phase 4b failed."
  assert_no_phase4c_marker "$case_dir"
  pass "Phase 4b failure prevents Phase 4c"
}

test_unresolved_password_skips_safely() {
  local case_dir
  case_dir="$(new_case unresolved)"
  run_installer "$case_dir"
  [[ ! -e "${case_dir}/root/opt/wg-easy" ]] \
    || fail "Unresolved WG_EASY_PASSWORD created wg-easy runtime state."
  ! grep -Fq 'docker:compose --project-name wg-easy' "${case_dir}/operations.log" \
    || fail "Unresolved WG_EASY_PASSWORD invoked wg-easy Compose."
  grep -Fq 'WG_EASY_PASSWORD is unresolved; Phase 4c is incomplete' \
    "${case_dir}/output.log" || fail "Unresolved password was not reported safely."
  grep -Fxq 'phase=4c' "${case_dir}/root/var/lib/nova-infra/phase4c-complete" \
    || fail "Accepted skipped state did not complete Phase 4c orchestration."
  pass "CHANGE_ME_WG_EASY_PASSWORD skips wg-easy without aborting"
}

test_compose_and_network_contract() {
  local case_dir compose
  case_dir="$(new_case compose-contract)"
  write_local_secrets "$case_dir" "$TEST_SECRET_PASSWORD"
  run_installer "$case_dir"
  compose="${case_dir}/root/opt/wg-easy/compose.yml"
  cmp -s -- "$COMPOSE_SOURCE" "$compose" || fail "Installed Compose file is not deterministic."
  grep -Fxq '    image: ghcr.io/wg-easy/wg-easy:15' "$compose" \
    || fail "wg-easy image is not pinned to major v15."
  grep -Fxq '    container_name: wg-easy' "$compose" || fail "Container name is not fixed."
  grep -Fxq '      - "0.0.0.0:51824:51824/udp"' "$compose" \
    || fail "IPv4-only UDP 51824 publication is missing."
  grep -Fxq '      - "127.0.0.1:51821:51821/tcp"' "$compose" \
    || fail "Web UI is not restricted to loopback."
  grep -Fxq '      - "/opt/wg-easy/data:/etc/wireguard"' "$compose" \
    || fail "Persistent data bind mount is missing."
  grep -Fxq '      DISABLE_IPV6: "true"' "$compose" || fail "VPN IPv6 is not disabled."
  grep -Fxq '      - NET_ADMIN' "$compose" && grep -Fxq '      - SYS_MODULE' "$compose" \
    || fail "Required explicit capabilities are missing."
  ! grep -Eq 'privileged:|watchtower|:latest|network_mode:[[:space:]]*host' "$compose" \
    || fail "Compose contains a forbidden privilege, update, latest, or host-network setting."
  grep -Fxq '      INIT_USERNAME: "admin"' "$INIT_SOURCE" \
    || fail "Unattended username is incorrect."
  grep -Fxq '      INIT_HOST: "bertrand.e-cloud.ch"' "$INIT_SOURCE" \
    || fail "WireGuard endpoint is incorrect."
  grep -Fxq '      INIT_PORT: "51824"' "$INIT_SOURCE" || fail "Init port is incorrect."
  grep -Fxq '      INIT_DNS: "10.9.0.1"' "$INIT_SOURCE" || fail "Client DNS is incorrect."
  grep -Fxq '      INIT_IPV4_CIDR: "10.9.0.0/24"' "$INIT_SOURCE" \
    || fail "VPN IPv4 network is incorrect."
  grep -Fxq '      INIT_ALLOWED_IPS: "0.0.0.0/0"' "$INIT_SOURCE" \
    || fail "IPv4 full-tunnel default is incorrect."
  pass "Compose uses exact v15 image, fixed name, persistent data, UDP 51824, and local-only UI"
}

test_secret_bootstrap_and_removal() {
  local case_dir
  case_dir="$(new_case secret-bootstrap)"
  write_local_secrets "$case_dir" "$TEST_SECRET_PASSWORD"
  run_installer "$case_dir"
  [[ -f "${case_dir}/docker-state/password-seen" ]] \
    || fail "The unattended initializer did not receive WG_EASY_PASSWORD."
  [[ ! -e "${case_dir}/docker-state/runtime-init-env" ]] \
    || fail "Initialization variables remained in the recreated container."
  assert_secret_absent "${case_dir}/output.log"
  assert_secret_absent "${case_dir}/operations.log"
  assert_secret_absent "$COMPOSE_SOURCE"
  assert_secret_absent "$INIT_SOURCE"
  pass "valid password initializes wg-easy without persistent or logged secret exposure"
}

test_persistence_and_restart_validation() {
  local case_dir database_hash
  case_dir="$(new_case persistence)"
  write_local_secrets "$case_dir" "$TEST_SECRET_PASSWORD"
  run_installer "$case_dir"
  database_hash="$(sha256sum "${case_dir}/root/opt/wg-easy/data/wg-easy.db")"
  [[ "$(count_lines "${case_dir}/docker-state/recreate.count")" == "1" ]] \
    || fail "Initial container was not recreated without init credentials."
  [[ "$(count_lines "${case_dir}/docker-state/restart.count")" == "1" ]] \
    || fail "Container restart validation did not run exactly once."
  [[ "$database_hash" == "$(sha256sum "${case_dir}/root/opt/wg-easy/data/wg-easy.db")" ]] \
    || fail "Persistent database changed unexpectedly during restart validation."
  grep -Fq 'docker:port wg-easy 51824/udp' "${case_dir}/operations.log" \
    || fail "WireGuard UDP publication was not validated."
  grep -Fq 'docker:exec wg-easy wg show wg0 listen-port' "${case_dir}/operations.log" \
    || fail "Active WireGuard listen port was not validated."
  grep -Fq 'docker:exec wg-easy ip -4 -o addr show dev wg0' "${case_dir}/operations.log" \
    || fail "Active Nova VPN address was not validated."
  grep -Fq 'docker:port wg-easy 51821/tcp' "${case_dir}/operations.log" \
    || fail "Web UI publication was not validated."
  pass "persistent state survives credential-removing recreate and validated restart"
}

test_repeated_execution_is_idempotent() {
  local case_dir compose_hash database_hash
  case_dir="$(new_case idempotence)"
  write_local_secrets "$case_dir" "$TEST_SECRET_PASSWORD"
  run_installer "$case_dir"
  compose_hash="$(sha256sum "${case_dir}/root/opt/wg-easy/compose.yml")"
  database_hash="$(sha256sum "${case_dir}/root/opt/wg-easy/data/wg-easy.db")"
  run_installer "$case_dir"
  [[ "$compose_hash" == "$(sha256sum "${case_dir}/root/opt/wg-easy/compose.yml")" \
    && "$database_hash" == "$(sha256sum "${case_dir}/root/opt/wg-easy/data/wg-easy.db")" ]] \
    || fail "Repeated execution changed managed Compose or persistent data."
  [[ "$(count_lines "${case_dir}/docker-state/init.count")" == "1" \
    && "$(count_lines "${case_dir}/docker-state/recreate.count")" == "1" \
    && "$(count_lines "${case_dir}/docker-state/pull.count")" == "2" \
    && "$(count_lines "${case_dir}/docker-state/restart.count")" == "2" ]] \
    || fail "Repeated execution repeated initialization or skipped normal validation."
  ! grep -Eq 'docker system prune|docker .*rm|/var/lib/docker|docker run' \
    "${case_dir}/operations.log" || fail "Repeated execution used destructive Docker behavior."
  pass "repeated Phase 4c preserves state and never repeats unattended initialization"
}

test_pull_failure_aborts_without_fallback() {
  local case_dir
  case_dir="$(new_case pull-failure)"
  write_local_secrets "$case_dir" "$TEST_SECRET_PASSWORD"
  NOVA_TEST_PHASE4C_FAIL_STEP=pull
  if run_installer "$case_dir"; then
    unset NOVA_TEST_PHASE4C_FAIL_STEP
    fail "Image pull failure unexpectedly completed Phase 4c."
  fi
  unset NOVA_TEST_PHASE4C_FAIL_STEP
  assert_no_phase4c_marker "$case_dir"
  ! grep -Eq 'docker.io|wg-easy/wg-easy:latest' "${case_dir}/operations.log" \
    || fail "Image pull failure used an unapproved fallback."
  pass "v15 image pull failure aborts without latest or alternate-image fallback"
}

test_unmanaged_container_is_not_replaced() {
  local case_dir
  case_dir="$(new_case unmanaged-container)"
  write_local_secrets "$case_dir" "$TEST_SECRET_PASSWORD"
  NOVA_TEST_COMPOSE_PROJECT=other-project
  NOVA_TEST_PREEXISTING_CONTAINER=1
  if run_installer "$case_dir"; then
    unset NOVA_TEST_COMPOSE_PROJECT NOVA_TEST_PREEXISTING_CONTAINER
    fail "Unmanaged wg-easy container was accepted."
  fi
  unset NOVA_TEST_COMPOSE_PROJECT NOVA_TEST_PREEXISTING_CONTAINER
  grep -Fq 'unmanaged container named wg-easy' "${case_dir}/output.log" \
    || fail "Unmanaged container conflict was not reported."
  [[ "$(count_lines "${case_dir}/docker-state/pull.count")" == "0" ]] \
    || fail "Phase 4c pulled or replaced an image after unmanaged-container conflict."
  assert_no_phase4c_marker "$case_dir"
  pass "existing unmanaged wg-easy container is never replaced destructively"
}

test_public_ui_exposure_is_rejected() {
  local case_dir
  case_dir="$(new_case public-ui)"
  write_local_secrets "$case_dir" "$TEST_SECRET_PASSWORD"
  NOVA_TEST_PUBLIC_UI=1
  if run_installer "$case_dir"; then
    unset NOVA_TEST_PUBLIC_UI
    fail "Public web UI binding unexpectedly passed validation."
  fi
  unset NOVA_TEST_PUBLIC_UI
  grep -Fq 'web UI is not restricted to host loopback port 51821' "${case_dir}/output.log" \
    || fail "Public UI exposure was not reported clearly."
  assert_no_phase4c_marker "$case_dir"
  pass "runtime validation rejects any non-loopback wg-easy web UI binding"
}

test_dns_unbound_and_firewall_remain_unchanged() {
  local case_dir resolver_hash unbound_hash nova_hash
  case_dir="$(new_case no-unrelated-network-changes)"
  write_local_secrets "$case_dir" "$TEST_SECRET_PASSWORD"
  resolver_hash="$(sha256sum "${case_dir}/root/etc/resolv.conf")"
  unbound_hash="$(sha256sum "${case_dir}/root/etc/unbound/unbound.conf")"
  run_installer "$case_dir"
  nova_hash="$(sha256sum "${case_dir}/root/etc/unbound/unbound.conf.d/nova.conf")"
  [[ "$resolver_hash" == "$(sha256sum "${case_dir}/root/etc/resolv.conf")" \
    && "$unbound_hash" == "$(sha256sum "${case_dir}/root/etc/unbound/unbound.conf")" \
    && "$nova_hash" == "$(sha256sum "${case_dir}/root/etc/unbound/unbound.conf.d/nova.conf")" ]] \
    || fail "Phase 4c changed resolver or Unbound configuration."
  ! grep -Eq '^(nft|iptables):|client(s)?:create|docker run|watchtower' \
    "${case_dir}/operations.log" \
    || fail "Phase 4c changed host firewall policy, created clients, or added auto-updates."
  pass "Phase 4c leaves DNS, Unbound, host firewall policy, and client inventory untouched"
}

printf 'TAP version 13\n'
test_phase_ordering
test_phase4b_failure_blocks_phase4c
test_unresolved_password_skips_safely
test_compose_and_network_contract
test_secret_bootstrap_and_removal
test_persistence_and_restart_validation
test_repeated_execution_is_idempotent
test_pull_failure_aborts_without_fallback
test_unmanaged_container_is_not_replaced
test_public_ui_exposure_is_rejected
test_dns_unbound_and_firewall_remain_unchanged
printf '1..%d\n' "$TESTS_RUN"
