#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_DIR="$(CDPATH= cd -- "${TEST_DIR}/.." && pwd)"
readonly INSTALLER="${REPOSITORY_DIR}/install.sh"
readonly TEST_WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/nova-phase2-tests.XXXXXX")"
readonly EXPECTED_PACKAGES="ca-certificates curl dnsutils git gnupg iproute2 iptables iputils-ping jq nftables procps rsync sudo unattended-upgrades unbound unzip wireguard-tools xz-utils"

TESTS_RUN=0

cleanup_tests() {
  local original_status=$?
  if [[ "$TEST_WORKSPACE" == "${TMPDIR:-/tmp}"/nova-phase2-tests.* && -d "$TEST_WORKSPACE" ]]; then
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
  local command_name

  mkdir -p -- \
    "${case_dir}/root/opt" \
    "${case_dir}/root/run" \
    "${case_dir}/root/etc/apt/sources.list.d" \
    "${case_dir}/root/proc/device-tree" \
    "${case_dir}/root/var/lib" \
    "${case_dir}/recovery/secrets" \
    "${case_dir}/mock-bin" \
    "${case_dir}/systemctl/active" \
    "${case_dir}/systemctl/enabled" \
    "${case_dir}/systemctl/masked"
  printf '%s\n' 'ID=debian' 'VERSION_ID="13"' 'VERSION_CODENAME=trixie' \
    > "${case_dir}/root/etc/os-release"
  printf 'Raspberry Pi 5 Model B Rev 1.0\0' > "${case_dir}/root/proc/device-tree/model"
  printf '%s\n' 'nameserver 192.0.2.53' > "${case_dir}/root/etc/resolv.conf"
  : > "${case_dir}/apt.log"
  : > "${case_dir}/operations.log"
  : > "${case_dir}/packages.state"
  : > "${case_dir}/phase1-events.log"

  cp -- "${REPOSITORY_DIR}/tests/phase2-mocks/apt-get" "${case_dir}/mock-bin/apt-get"
  cp -- "${REPOSITORY_DIR}/tests/phase2-mocks/curl" "${case_dir}/mock-bin/curl"
  cp -- "${REPOSITORY_DIR}/tests/phase2-mocks/dpkg" "${case_dir}/mock-bin/dpkg"
  cp -- "${REPOSITORY_DIR}/tests/phase2-mocks/dpkg-query" "${case_dir}/mock-bin/dpkg-query"
  cp -- "${REPOSITORY_DIR}/tests/phase2-mocks/gpg" "${case_dir}/mock-bin/gpg"
  cp -- "${REPOSITORY_DIR}/tests/phase2-mocks/systemctl" "${case_dir}/mock-bin/systemctl"
  for command_name in dig ip jq nft ping rsync ss sudo sysctl unbound unbound-checkconf unzip wg xz; do
    cp -- "${REPOSITORY_DIR}/tests/phase2-mocks/available-command" \
      "${case_dir}/mock-bin/${command_name}"
  done
  chmod +x -- "${case_dir}/mock-bin/"*
  printf '%s' "$case_dir"
}

run_installer() {
  local case_dir="$1"
  local output_file="${case_dir}/output.log"

  NOVA_INSTALL_PHASES=2 \
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
  NOVA_PHASE2_TEST_FAIL_STEP="${NOVA_TEST_FAIL_STEP:-}" \
  NOVA_PHASE2_TEST_MISSING_PACKAGE="${NOVA_TEST_MISSING_PACKAGE:-}" \
  PATH="${case_dir}/mock-bin:${PATH}" \
    "$INSTALLER" > "$output_file" 2>&1
}

assert_no_phase2_marker() {
  local case_dir="$1"
  [[ ! -e "${case_dir}/root/var/lib/nova-infra/phase2-complete" ]] \
    || fail "Failed Phase 2 unexpectedly wrote its completion marker."
}

test_phase1_runs_before_phase2() {
  local case_dir phase1_line phase2_line
  case_dir="$(new_case ordering)"
  run_installer "$case_dir"
  phase1_line="$(grep -n -m1 'Phase 1 preflight checks' "${case_dir}/output.log")"
  phase2_line="$(grep -n -m1 'Phase 2 preflight checks' "${case_dir}/output.log")"
  phase1_line="${phase1_line%%:*}"
  phase2_line="${phase2_line%%:*}"
  (( phase1_line < phase2_line )) || fail "Phase 2 did not start after Phase 1."
  [[ -f "${case_dir}/root/opt/nova-bootstrap/secrets.env" ]] \
    || fail "Phase 1 secret bootstrap did not complete before Phase 2."
  pass "Phase 1 completes before Phase 2 starts"
}

test_apt_update_failure_aborts() {
  local case_dir
  case_dir="$(new_case update-failure)"
  NOVA_TEST_FAIL_STEP=update
  if run_installer "$case_dir"; then
    unset NOVA_TEST_FAIL_STEP
    fail "APT update failure unexpectedly succeeded."
  fi
  unset NOVA_TEST_FAIL_STEP
  grep -Fq 'APT metadata update failed' "${case_dir}/output.log" \
    || fail "APT update failure was not reported clearly."
  ! grep -q '^apt:full-upgrade$' "${case_dir}/operations.log" \
    || fail "Full upgrade ran after APT update failure."
  assert_no_phase2_marker "$case_dir"
  pass "APT update failure aborts before upgrade or installation"
}

test_full_upgrade_failure_aborts() {
  local case_dir
  case_dir="$(new_case upgrade-failure)"
  NOVA_TEST_FAIL_STEP=full-upgrade
  if run_installer "$case_dir"; then
    unset NOVA_TEST_FAIL_STEP
    fail "Full-upgrade failure unexpectedly succeeded."
  fi
  unset NOVA_TEST_FAIL_STEP
  grep -Fq 'APT full-upgrade failed' "${case_dir}/output.log" \
    || fail "Full-upgrade failure was not reported clearly."
  ! grep -q '^apt:install$' "${case_dir}/operations.log" \
    || fail "Package installation ran after full-upgrade failure."
  assert_no_phase2_marker "$case_dir"
  pass "full-upgrade failure aborts before package installation"
}

test_package_install_failure_aborts() {
  local case_dir
  case_dir="$(new_case install-failure)"
  NOVA_TEST_FAIL_STEP=install
  if run_installer "$case_dir"; then
    unset NOVA_TEST_FAIL_STEP
    fail "Package installation failure unexpectedly succeeded."
  fi
  unset NOVA_TEST_FAIL_STEP
  grep -Fq 'APT base package installation failed' "${case_dir}/output.log" \
    || fail "Package installation failure was not reported clearly."
  [[ ! -e "${case_dir}/root/etc/apt/sources.list.d/docker.sources" ]] \
    || fail "External repositories were configured after package failure."
  assert_no_phase2_marker "$case_dir"
  pass "package installation failure aborts before repository preparation"
}

test_package_list_is_deterministic() {
  local case_dir package_line
  case_dir="$(new_case deterministic-packages)"
  run_installer "$case_dir"
  package_line="$(grep '^packages:' "${case_dir}/operations.log")"
  [[ "$package_line" == "packages:${EXPECTED_PACKAGES}" ]] \
    || fail "Phase 2 package list or ordering is not deterministic."
  pass "base package list is exact, consolidated, and deterministic"
}

test_repeated_execution_is_idempotent() {
  local case_dir docker_before syncthing_before key_before
  case_dir="$(new_case idempotence)"
  run_installer "$case_dir"
  docker_before="$(sha256sum "${case_dir}/root/etc/apt/sources.list.d/docker.sources")"
  syncthing_before="$(sha256sum "${case_dir}/root/etc/apt/sources.list.d/syncthing.list")"
  key_before="$(sha256sum "${case_dir}/root/etc/apt/keyrings/docker.asc")"
  run_installer "$case_dir"

  [[ "$docker_before" == "$(sha256sum "${case_dir}/root/etc/apt/sources.list.d/docker.sources")" ]] \
    || fail "Repeated execution changed deterministic Docker repository content."
  [[ "$syncthing_before" == "$(sha256sum "${case_dir}/root/etc/apt/sources.list.d/syncthing.list")" ]] \
    || fail "Repeated execution changed deterministic Syncthing repository content."
  [[ "$key_before" == "$(sha256sum "${case_dir}/root/etc/apt/keyrings/docker.asc")" ]] \
    || fail "Repeated execution changed identical key content."
  [[ "$(grep -c '^URIs: https://download.docker.com/linux/debian$' "${case_dir}/root/etc/apt/sources.list.d/docker.sources")" == "1" ]] \
    || fail "Docker repository was duplicated."
  [[ "$(grep -c '^deb .*https://apt.syncthing.net/' "${case_dir}/root/etc/apt/sources.list.d/syncthing.list")" == "1" ]] \
    || fail "Syncthing repository was duplicated."
  pass "repeated Phase 2 execution is idempotent without duplicate repositories"
}

test_no_apt_cacher_or_resolver_changes() {
  local case_dir resolver_before
  case_dir="$(new_case no-network-config)"
  resolver_before="$(sha256sum "${case_dir}/root/etc/resolv.conf")"
  run_installer "$case_dir"

  [[ "$resolver_before" == "$(sha256sum "${case_dir}/root/etc/resolv.conf")" ]] \
    || fail "Phase 2 changed resolver configuration."
  if grep -R -i -E 'apt-cacher-ng|Acquire::(http|https)::Proxy' "${case_dir}/root/etc/apt" >/dev/null 2>&1; then
    fail "Phase 2 introduced apt-cacher-ng or an APT proxy."
  fi
  [[ ! -e "${case_dir}/root/etc/unbound" ]] \
    || fail "Phase 2 wrote premature Unbound or port-53 configuration."
  pass "no apt-cacher, resolver, DNS, or port-53 configuration is introduced"
}

test_critical_service_safety_is_enforced() {
  local case_dir mask_line install_line disable_line
  case_dir="$(new_case service-safety)"
  run_installer "$case_dir"

  mask_line="$(grep -n -m1 '^systemctl:mask:--runtime unbound.service$' "${case_dir}/operations.log")"
  install_line="$(grep -n -m1 '^apt:install$' "${case_dir}/operations.log")"
  disable_line="$(grep -n -m1 '^systemctl:disable:--now unbound.service$' "${case_dir}/operations.log")"
  mask_line="${mask_line%%:*}"
  install_line="${install_line%%:*}"
  disable_line="${disable_line%%:*}"
  (( mask_line < install_line && install_line < disable_line )) \
    || fail "Critical Unbound unit was not protected throughout package installation."
  [[ ! -e "${case_dir}/systemctl/active/unbound.service" \
    && ! -e "${case_dir}/systemctl/enabled/unbound.service" ]] \
    || fail "Unbound remained active or enabled after Phase 2."
  [[ ! -e "${case_dir}/systemctl/masked/unbound.service" \
    && ! -e "${case_dir}/systemctl/masked/nftables.service" ]] \
    || fail "Temporary service masks were not cleaned up."
  ! grep -q '^simulated-autostart:' "${case_dir}/operations.log" \
    || fail "A critical package service auto-started despite temporary protection."
  pass "critical DNS and firewall service auto-start is prevented and verified"
}

test_missing_package_is_reported() {
  local case_dir
  case_dir="$(new_case package-unavailable)"
  NOVA_TEST_MISSING_PACKAGE=jq
  if run_installer "$case_dir"; then
    unset NOVA_TEST_MISSING_PACKAGE
    fail "Missing required package unexpectedly passed availability checks."
  fi
  unset NOVA_TEST_MISSING_PACKAGE
  grep -Fq 'Required base package is unavailable after installation: jq' "${case_dir}/output.log" \
    || fail "Missing package was not reported by name."
  assert_no_phase2_marker "$case_dir"
  pass "post-install package availability failure aborts clearly"
}

printf 'TAP version 13\n'
test_phase1_runs_before_phase2
test_apt_update_failure_aborts
test_full_upgrade_failure_aborts
test_package_install_failure_aborts
test_package_list_is_deterministic
test_repeated_execution_is_idempotent
test_no_apt_cacher_or_resolver_changes
test_critical_service_safety_is_enforced
test_missing_package_is_reported
printf '1..%d\n' "$TESTS_RUN"
