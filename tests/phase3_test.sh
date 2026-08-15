#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_DIR="$(CDPATH= cd -- "${TEST_DIR}/.." && pwd)"
readonly INSTALLER="${REPOSITORY_DIR}/install.sh"
readonly TEST_WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/nova-phase3-tests.XXXXXX")"
readonly EXPECTED_DOCKER_PACKAGES="containerd.io docker-buildx-plugin docker-ce docker-ce-cli docker-compose-plugin"

TESTS_RUN=0

cleanup_tests() {
  local original_status=$?
  if [[ "$TEST_WORKSPACE" == "${TMPDIR:-/tmp}"/nova-phase3-tests.* && -d "$TEST_WORKSPACE" ]]; then
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
  for mock_name in apt-cache apt-get dpkg-query getent id systemctl usermod; do
    cp -- "${REPOSITORY_DIR}/tests/phase3-mocks/${mock_name}" \
      "${case_dir}/mock-bin/${mock_name}"
  done
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

  NOVA_INSTALL_PHASES=3 \
  NOVA_PHASE1_TEST_MODE=1 \
  NOVA_PHASE1_TEST_ROOT="${case_dir}/root" \
  NOVA_PHASE1_TEST_ARCH="${NOVA_TEST_PHASE1_ARCH:-aarch64}" \
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
  NOVA_PHASE3_TEST_INSTALL_FAIL="${NOVA_TEST_DOCKER_INSTALL_FAIL:-0}" \
  NOVA_PHASE3_TEST_MISSING_PACKAGE="${NOVA_TEST_DOCKER_MISSING_PACKAGE:-}" \
  NOVA_PHASE3_TEST_ADMIN_PRESENT="${NOVA_TEST_ADMIN_PRESENT:-1}" \
  PATH="${case_dir}/mock-bin:${PATH}" \
    "$INSTALLER" > "$output_file" 2>&1
}

assert_no_phase3_marker() {
  local case_dir="$1"
  [[ ! -e "${case_dir}/root/var/lib/nova-infra/phase3-complete" ]] \
    || fail "Failed Phase 3 unexpectedly wrote its completion marker."
}

test_phase_ordering() {
  local case_dir phase1_line phase2_line phase3_line
  case_dir="$(new_case ordering)"
  run_installer "$case_dir"
  phase1_line="$(grep -n -m1 'Phase 1 preflight checks' "${case_dir}/output.log")"
  phase2_line="$(grep -n -m1 'Phase 2 preflight checks' "${case_dir}/output.log")"
  phase3_line="$(grep -n -m1 'Phase 3 preflight checks' "${case_dir}/output.log")"
  phase1_line="${phase1_line%%:*}"
  phase2_line="${phase2_line%%:*}"
  phase3_line="${phase3_line%%:*}"
  (( phase1_line < phase2_line && phase2_line < phase3_line )) \
    || fail "Installer phase ordering is incorrect."
  pass "Phase 3 starts only after successful Phase 1 and Phase 2"
}

test_phase1_failure_blocks_later_phases() {
  local case_dir
  case_dir="$(new_case phase1-failure)"
  NOVA_TEST_PHASE1_ARCH=x86_64
  if run_installer "$case_dir"; then
    unset NOVA_TEST_PHASE1_ARCH
    fail "Phase 1 failure unexpectedly allowed the installer to succeed."
  fi
  unset NOVA_TEST_PHASE1_ARCH
  ! grep -Fq 'Phase 2 preflight checks' "${case_dir}/output.log" \
    || fail "Phase 2 ran after Phase 1 failed."
  ! grep -Fq 'Phase 3 preflight checks' "${case_dir}/output.log" \
    || fail "Phase 3 ran after Phase 1 failed."
  assert_no_phase3_marker "$case_dir"
  pass "Phase 1 failure prevents Phase 2 and Phase 3"
}

test_phase2_failure_blocks_phase3() {
  local case_dir
  case_dir="$(new_case phase2-failure)"
  NOVA_TEST_PHASE2_FAIL_STEP=update
  if run_installer "$case_dir"; then
    unset NOVA_TEST_PHASE2_FAIL_STEP
    fail "Phase 2 failure unexpectedly allowed the installer to succeed."
  fi
  unset NOVA_TEST_PHASE2_FAIL_STEP
  ! grep -Fq 'Phase 3 preflight checks' "${case_dir}/output.log" \
    || fail "Phase 3 ran after Phase 2 failed."
  assert_no_phase3_marker "$case_dir"
  pass "Phase 2 failure prevents Phase 3"
}

test_official_packages_are_exact() {
  local case_dir package_line package
  case_dir="$(new_case official-packages)"
  run_installer "$case_dir"
  package_line="$(grep '^docker-packages:' "${case_dir}/operations.log")"
  [[ "$package_line" == "docker-packages:${EXPECTED_DOCKER_PACKAGES}" ]] \
    || fail "Phase 3 did not install the exact official Docker package set."
  ! grep -Eq 'docker-packages:.*(^|[[:space:]])docker\.io($|[[:space:]])' \
    "${case_dir}/operations.log" \
    || fail "Phase 3 requested Debian docker.io."
  for package in $EXPECTED_DOCKER_PACKAGES; do
    grep -Fq "apt-cache:policy:${package}" "${case_dir}/operations.log" \
      || fail "Official candidate was not checked for ${package}."
  done
  pass "exact official Docker packages are selected without docker.io fallback"
}

test_unavailable_official_repository_aborts() {
  local case_dir
  case_dir="$(new_case repository-unavailable)"
  NOVA_TEST_DOCKER_REPOSITORY_AVAILABLE=0
  if run_installer "$case_dir"; then
    unset NOVA_TEST_DOCKER_REPOSITORY_AVAILABLE
    fail "Unavailable official Docker repository unexpectedly succeeded."
  fi
  unset NOVA_TEST_DOCKER_REPOSITORY_AVAILABLE
  grep -Fq 'No official Docker repository candidate is available' "${case_dir}/output.log" \
    || fail "Unavailable official Docker candidates were not reported clearly."
  ! grep -q '^docker-packages:' "${case_dir}/operations.log" \
    || fail "Docker package installation ran without official candidates."
  assert_no_phase3_marker "$case_dir"
  pass "official repository failure aborts without Debian package fallback"
}

test_incompatible_docker_io_aborts() {
  local case_dir
  case_dir="$(new_case incompatible-docker-io)"
  printf '%s\n' 'docker.io' >> "${case_dir}/packages.state"
  if run_installer "$case_dir"; then
    fail "Existing incompatible docker.io unexpectedly succeeded."
  fi
  grep -Fq 'Incompatible existing container package detected: docker.io' \
    "${case_dir}/output.log" \
    || fail "Existing docker.io was not rejected clearly."
  ! grep -q '^docker-packages:' "${case_dir}/operations.log" \
    || fail "Phase 3 attempted replacement after finding docker.io."
  assert_no_phase3_marker "$case_dir"
  pass "existing incompatible docker.io is rejected without replacement"
}

test_package_install_failure_aborts() {
  local case_dir
  case_dir="$(new_case install-failure)"
  NOVA_TEST_DOCKER_INSTALL_FAIL=1
  if run_installer "$case_dir"; then
    unset NOVA_TEST_DOCKER_INSTALL_FAIL
    fail "Docker package installation failure unexpectedly succeeded."
  fi
  unset NOVA_TEST_DOCKER_INSTALL_FAIL
  grep -Fq 'Official Docker package installation failed' "${case_dir}/output.log" \
    || fail "Docker package installation failure was not reported clearly."
  ! grep -q '^systemctl:enable:--now docker.service$' "${case_dir}/operations.log" \
    || fail "Docker service enable ran after package installation failed."
  assert_no_phase3_marker "$case_dir"
  pass "Docker package installation failure aborts safely"
}

test_services_are_enabled_and_active() {
  local case_dir
  case_dir="$(new_case service-state)"
  run_installer "$case_dir"
  for unit in containerd.service docker.service; do
    [[ -e "${case_dir}/systemctl/enabled/${unit}" ]] \
      || fail "${unit} was not enabled."
    [[ -e "${case_dir}/systemctl/active/${unit}" ]] \
      || fail "${unit} was not active."
    grep -Fq "systemctl:enable:--now ${unit}" "${case_dir}/operations.log" \
      || fail "Phase 3 did not explicitly enable and start ${unit}."
  done
  pass "Docker and containerd services are enabled and active"
}

test_admin_group_membership_is_idempotent() {
  local case_dir
  case_dir="$(new_case admin-group)"
  run_installer "$case_dir"
  grep -Fq 'A new login session is required' "${case_dir}/output.log" \
    || fail "New-session requirement was not reported after group change."
  run_installer "$case_dir"
  [[ "$(grep -o '\bdocker\b' "${case_dir}/admin.groups" | wc -l | tr -d ' ')" == "1" ]] \
    || fail "docker group membership was duplicated."
  [[ "$(grep -c '^usermod:-aG docker admin$' "${case_dir}/operations.log")" == "1" ]] \
    || fail "admin group membership update was not idempotent."
  pass "admin docker-group membership is added once and remains idempotent"
}

test_repeated_execution_preserves_docker_state() {
  local case_dir container_before
  case_dir="$(new_case repeated-execution)"
  run_installer "$case_dir"
  printf '%s\n' 'existing-container-id' > "${case_dir}/containers.state"
  container_before="$(sha256sum "${case_dir}/containers.state")"
  run_installer "$case_dir"
  [[ "$container_before" == "$(sha256sum "${case_dir}/containers.state")" ]] \
    || fail "Repeated Phase 3 changed existing container state."
  [[ "$(grep -c '^docker-packages:' "${case_dir}/operations.log")" == "2" ]] \
    || fail "Repeated Phase 3 did not remain safely install-idempotent."
  pass "repeated Phase 3 execution preserves existing Docker state"
}

test_no_workloads_prune_dns_or_firewall_changes() {
  local case_dir resolver_before
  case_dir="$(new_case no-workloads)"
  resolver_before="$(sha256sum "${case_dir}/root/etc/resolv.conf")"
  run_installer "$case_dir"

  [[ "$resolver_before" == "$(sha256sum "${case_dir}/root/etc/resolv.conf")" ]] \
    || fail "Phase 3 changed resolver configuration."
  [[ ! -s "${case_dir}/containers.state" ]] \
    || fail "Phase 3 created an application container."
  if grep -Eq '^docker:(run|create|start|stop|restart|pull|rm|rmi|compose up|system prune|container prune|image prune|volume prune)' \
    "${case_dir}/operations.log"; then
    fail "Phase 3 issued a workload or destructive Docker command."
  fi
  if grep -Eq 'docker[[:space:]]+(system[[:space:]]+prune|run|create|pull|rm|rmi)' \
    "${REPOSITORY_DIR}/lib/phase3.sh"; then
    fail "Phase 3 implementation contains a prohibited Docker operation."
  fi
  [[ ! -e "${case_dir}/root/etc/docker/daemon.json" ]] \
    || fail "Phase 3 wrote an unsolicited Docker daemon configuration."
  pass "Phase 3 creates no workloads and performs no prune, DNS, or manual firewall configuration"
}

printf 'TAP version 13\n'
test_phase_ordering
test_phase1_failure_blocks_later_phases
test_phase2_failure_blocks_phase3
test_official_packages_are_exact
test_unavailable_official_repository_aborts
test_incompatible_docker_io_aborts
test_package_install_failure_aborts
test_services_are_enabled_and_active
test_admin_group_membership_is_idempotent
test_repeated_execution_preserves_docker_state
test_no_workloads_prune_dns_or_firewall_changes
printf '1..%d\n' "$TESTS_RUN"
