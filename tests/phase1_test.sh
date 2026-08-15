#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_DIR="$(CDPATH= cd -- "${TEST_DIR}/.." && pwd)"
readonly INSTALLER="${REPOSITORY_DIR}/install.sh"
readonly TEST_WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/nova-phase1-tests.XXXXXX")"

TESTS_RUN=0

cleanup_tests() {
  local original_status=$?
  if [[ "$TEST_WORKSPACE" == "${TMPDIR:-/tmp}"/nova-phase1-tests.* && -d "$TEST_WORKSPACE" ]]; then
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

assert_file_contains() {
  local file="$1"
  local expected="$2"
  grep -Fqx -- "$expected" "$file" || fail "Expected assignment was not found."
}

assert_output_excludes() {
  local file="$1"
  local forbidden="$2"
  if grep -Fq -- "$forbidden" "$file"; then
    fail "Normal output exposed a test secret value."
  fi
}

new_case() {
  local name="$1"
  local case_dir="${TEST_WORKSPACE}/${name}"

  mkdir -p -- "${case_dir}/root/opt" "${case_dir}/root/run" \
    "${case_dir}/root/etc" "${case_dir}/root/proc/device-tree"
  printf '%s\n' \
    'ID=debian' \
    'VERSION_ID="13"' \
    'VERSION_CODENAME=trixie' > "${case_dir}/root/etc/os-release"
  printf 'Raspberry Pi 5 Model B Rev 1.0\0' > "${case_dir}/root/proc/device-tree/model"
  mkdir -p -- "${case_dir}/recovery/secrets"
  : > "${case_dir}/events.log"
  printf '%s' "$case_dir"
}

run_phase1() {
  local case_dir="$1"
  local recovery_source="${2:-}"
  local already_mounted="${3:-0}"
  local output_file="${case_dir}/output.log"

  NOVA_PHASE1_TEST_MODE=1 \
  NOVA_PHASE1_TEST_ROOT="${case_dir}/root" \
  NOVA_PHASE1_TEST_ARCH="${NOVA_TEST_ARCH_OVERRIDE:-aarch64}" \
  NOVA_PHASE1_TEST_EUID="${NOVA_TEST_EUID_OVERRIDE:-0}" \
  NOVA_PHASE1_TEST_NETWORK_OK="${NOVA_TEST_NETWORK_OVERRIDE:-1}" \
  NOVA_PHASE1_TEST_RECOVERY_SOURCE="$recovery_source" \
  NOVA_PHASE1_TEST_RECOVERY_ALREADY_MOUNTED="$already_mounted" \
  NOVA_PHASE1_TEST_EVENT_LOG="${case_dir}/events.log" \
  NOVA_PHASE1_TEST_USE_PRODUCTION_RECOVERY="${NOVA_TEST_USE_PRODUCTION_RECOVERY:-0}" \
  NOVA_MOCK_RECOVERY_SOURCE="${NOVA_TEST_MOCK_RECOVERY_SOURCE:-}" \
  NOVA_MOCK_MOUNT_STATE="${NOVA_TEST_MOCK_MOUNT_STATE:-}" \
  NOVA_MOCK_MOUNT_LOG="${NOVA_TEST_MOCK_MOUNT_LOG:-}" \
  PATH="${NOVA_TEST_PATH_OVERRIDE:-$PATH}" \
    "$INSTALLER" > "$output_file" 2>&1
}

write_all_recovery_secrets() {
  local file="$1"
  printf '%s\n' \
    'DYNDNS_URL=https://freedns.invalid/update?token=TEST_SECRET_DYNDNS&mode=a&b=$literal' \
    "CAMERA_URL='rtsp://camera.invalid/TEST_SECRET_CAMERA?x=1&y=two words'" \
    'TOKEN="TEST_SECRET_TOKEN;$HOME&`not-executed`"' \
    'ADGUARD_PASSWORD_HASH=$2y$10$TEST_SECRET_HASH/with=specials' > "$file"
}

test_no_recovery() {
  local case_dir local_file
  case_dir="$(new_case no-recovery)"
  run_phase1 "$case_dir"
  local_file="${case_dir}/root/opt/nova-bootstrap/secrets.env"

  assert_file_contains "$local_file" 'DYNDNS_URL=CHANGE_ME_DYNDNS_URL'
  assert_file_contains "$local_file" 'CAMERA_URL=CHANGE_ME_CAMERA_URL'
  assert_file_contains "$local_file" 'TOKEN=CHANGE_ME_TOKEN'
  assert_file_contains "$local_file" 'ADGUARD_PASSWORD_HASH=CHANGE_ME_ADGUARD_PASSWORD_HASH'
  grep -Fq 'Unresolved secret variables: DYNDNS_URL CAMERA_URL TOKEN ADGUARD_PASSWORD_HASH' "${case_dir}/output.log" \
    || fail "Missing recovery did not report unresolved names."
  pass "no INFRA-RECOVERY continues with named placeholders"
}

test_recovery_with_all_secrets() {
  local case_dir local_file
  case_dir="$(new_case all-secrets)"
  write_all_recovery_secrets "${case_dir}/recovery/secrets/secrets.env"
  run_phase1 "$case_dir" "${case_dir}/recovery" 1
  local_file="${case_dir}/root/opt/nova-bootstrap/secrets.env"

  assert_file_contains "$local_file" 'DYNDNS_URL=https://freedns.invalid/update?token=TEST_SECRET_DYNDNS&mode=a&b=$literal'
  assert_file_contains "$local_file" 'CAMERA_URL=rtsp://camera.invalid/TEST_SECRET_CAMERA?x=1&y=two words'
  assert_file_contains "$local_file" 'TOKEN=TEST_SECRET_TOKEN;$HOME&`not-executed`'
  assert_file_contains "$local_file" 'ADGUARD_PASSWORD_HASH=$2y$10$TEST_SECRET_HASH/with=specials'
  if grep -q '^umount:' "${case_dir}/events.log"; then
    fail "An existing recovery mount was cleaned up by the installer."
  fi
  pass "mounted recovery supplies all four shell-special values safely"
}

test_missing_recovery_values() {
  local case_dir local_file
  case_dir="$(new_case missing-values)"
  printf '%s\n' 'TOKEN=TEST_SECRET_ONLY_TOKEN' > "${case_dir}/recovery/secrets/secrets.env"
  run_phase1 "$case_dir" "${case_dir}/recovery" 1
  local_file="${case_dir}/root/opt/nova-bootstrap/secrets.env"

  assert_file_contains "$local_file" 'TOKEN=TEST_SECRET_ONLY_TOKEN'
  assert_file_contains "$local_file" 'DYNDNS_URL=CHANGE_ME_DYNDNS_URL'
  grep -Fq 'Unresolved secret variables: DYNDNS_URL CAMERA_URL ADGUARD_PASSWORD_HASH' "${case_dir}/output.log" \
    || fail "Missing individual values were not reported by name."
  pass "missing individual values become placeholders without aborting"
}

test_existing_real_values_are_preserved() {
  local case_dir local_file
  case_dir="$(new_case preserve-existing)"
  mkdir -p -- "${case_dir}/root/opt/nova-bootstrap"
  local_file="${case_dir}/root/opt/nova-bootstrap/secrets.env"
  printf '%s\n' \
    'DYNDNS_URL=TEST_SECRET_LOCAL_DYNDNS' \
    'CAMERA_URL=TEST_SECRET_LOCAL_CAMERA' \
    'TOKEN=TEST_SECRET_LOCAL_TOKEN' \
    'ADGUARD_PASSWORD_HASH=TEST_SECRET_LOCAL_HASH' > "$local_file"

  run_phase1 "$case_dir"
  assert_file_contains "$local_file" 'TOKEN=TEST_SECRET_LOCAL_TOKEN'
  assert_file_contains "$local_file" 'DYNDNS_URL=TEST_SECRET_LOCAL_DYNDNS'
  pass "existing real local values are preserved"
}

test_placeholder_is_replaced() {
  local case_dir local_file
  case_dir="$(new_case replace-placeholder)"
  mkdir -p -- "${case_dir}/root/opt/nova-bootstrap"
  local_file="${case_dir}/root/opt/nova-bootstrap/secrets.env"
  printf '%s\n' \
    'DYNDNS_URL=CHANGE_ME_DYNDNS_URL' \
    'CAMERA_URL=CHANGE_ME_CAMERA_URL' \
    'TOKEN=CHANGE_ME_TOKEN' \
    'ADGUARD_PASSWORD_HASH=CHANGE_ME_ADGUARD_PASSWORD_HASH' > "$local_file"
  printf '%s\n' 'TOKEN=TEST_SECRET_RECOVERED_TOKEN' > "${case_dir}/recovery/secrets/secrets.env"

  run_phase1 "$case_dir" "${case_dir}/recovery" 1
  assert_file_contains "$local_file" 'TOKEN=TEST_SECRET_RECOVERED_TOKEN'
  pass "recovered real value replaces only its local placeholder"
}

test_conflicting_real_values_fail_safely() {
  local case_dir local_file before_file
  case_dir="$(new_case conflict)"
  mkdir -p -- "${case_dir}/root/opt/nova-bootstrap"
  local_file="${case_dir}/root/opt/nova-bootstrap/secrets.env"
  before_file="${case_dir}/before.env"
  printf '%s\n' \
    'DYNDNS_URL=TEST_SECRET_LOCAL_CONFLICT' \
    'CAMERA_URL=CHANGE_ME_CAMERA_URL' \
    'TOKEN=CHANGE_ME_TOKEN' \
    'ADGUARD_PASSWORD_HASH=CHANGE_ME_ADGUARD_PASSWORD_HASH' > "$local_file"
  cp -- "$local_file" "$before_file"
  printf '%s\n' 'DYNDNS_URL=TEST_SECRET_RECOVERY_CONFLICT' > "${case_dir}/recovery/secrets/secrets.env"

  if run_phase1 "$case_dir" "${case_dir}/recovery" 1; then
    fail "Conflicting real values unexpectedly succeeded."
  fi
  cmp -s -- "$local_file" "$before_file" || fail "Conflict changed the existing local file."
  grep -Fq 'Conflicting real local and recovery values for: DYNDNS_URL' "${case_dir}/output.log" \
    || fail "Conflict did not report the variable name."
  assert_output_excludes "${case_dir}/output.log" 'TEST_SECRET_LOCAL_CONFLICT'
  assert_output_excludes "${case_dir}/output.log" 'TEST_SECRET_RECOVERY_CONFLICT'
  pass "different real values fail safely and leave the local file unchanged"
}

test_repeated_execution_is_idempotent() {
  local case_dir local_file snapshot
  case_dir="$(new_case idempotence)"
  write_all_recovery_secrets "${case_dir}/recovery/secrets/secrets.env"
  run_phase1 "$case_dir" "${case_dir}/recovery" 1
  local_file="${case_dir}/root/opt/nova-bootstrap/secrets.env"
  snapshot="${case_dir}/first.env"
  cp -- "$local_file" "$snapshot"
  run_phase1 "$case_dir" "${case_dir}/recovery" 1

  cmp -s -- "$local_file" "$snapshot" || fail "Repeated execution changed merged secret content."
  grep -Fq 'already contains the merged values' "${case_dir}/output.log" \
    || fail "Repeated execution was not reported as unchanged."
  pass "repeated execution is idempotent"
}

test_resulting_mode_is_0600() {
  local case_dir local_file mode
  case_dir="$(new_case mode)"
  run_phase1 "$case_dir"
  local_file="${case_dir}/root/opt/nova-bootstrap/secrets.env"
  mode="$(stat -c '%a' -- "$local_file")"
  if [[ "$mode" != "600" ]]; then
    grep -Fqx "mode:${local_file}:0600" "${case_dir}/events.log" \
      || fail "Resulting secrets file mode was not set to 0600."
  fi
  pass "resulting local secrets file mode is 0600"
}

test_output_never_contains_values() {
  local case_dir
  case_dir="$(new_case no-output-leak)"
  write_all_recovery_secrets "${case_dir}/recovery/secrets/secrets.env"
  run_phase1 "$case_dir" "${case_dir}/recovery" 1

  assert_output_excludes "${case_dir}/output.log" 'TEST_SECRET_DYNDNS'
  assert_output_excludes "${case_dir}/output.log" 'TEST_SECRET_CAMERA'
  assert_output_excludes "${case_dir}/output.log" 'TEST_SECRET_TOKEN'
  assert_output_excludes "${case_dir}/output.log" 'TEST_SECRET_HASH'
  pass "normal output contains no secret values"
}

test_installer_mount_is_cleaned_up() {
  local case_dir mount_event mountpoint
  case_dir="$(new_case mount-cleanup)"
  write_all_recovery_secrets "${case_dir}/recovery/secrets/secrets.env"
  run_phase1 "$case_dir" "${case_dir}/recovery" 0

  mount_event="$(grep '^mount:' "${case_dir}/events.log")"
  [[ "$mount_event" == *':ro,nosuid,nodev,noexec' ]] \
    || fail "Installer-created recovery mount was not requested read-only."
  mountpoint="${mount_event#mount:}"
  mountpoint="${mountpoint%:ro,nosuid,nodev,noexec}"
  [[ ! -e "$mountpoint" ]] || fail "Installer-created recovery mountpoint was not cleaned up."
  grep -Fqx "umount:${mountpoint}" "${case_dir}/events.log" \
    || fail "Installer-created recovery mount cleanup was not recorded."
  pass "only the installer-created read-only recovery mount is cleaned up"
}

test_production_recovery_discovery_with_mocks() {
  local case_dir local_file mount_event mountpoint
  case_dir="$(new_case production-recovery-mocks)"
  write_all_recovery_secrets "${case_dir}/recovery/secrets/secrets.env"
  : > "${case_dir}/mount.log"

  NOVA_TEST_USE_PRODUCTION_RECOVERY=1
  NOVA_TEST_MOCK_RECOVERY_SOURCE="${case_dir}/recovery"
  NOVA_TEST_MOCK_MOUNT_STATE="${case_dir}/mount.state"
  NOVA_TEST_MOCK_MOUNT_LOG="${case_dir}/mount.log"
  NOVA_TEST_PATH_OVERRIDE="${REPOSITORY_DIR}/tests/mocks:${PATH}"
  run_phase1 "$case_dir"
  unset NOVA_TEST_USE_PRODUCTION_RECOVERY NOVA_TEST_MOCK_RECOVERY_SOURCE \
    NOVA_TEST_MOCK_MOUNT_STATE NOVA_TEST_MOCK_MOUNT_LOG NOVA_TEST_PATH_OVERRIDE

  local_file="${case_dir}/root/opt/nova-bootstrap/secrets.env"
  assert_file_contains "$local_file" 'TOKEN=TEST_SECRET_TOKEN;$HOME&`not-executed`'
  mount_event="$(grep '^mount:' "${case_dir}/mount.log")"
  [[ "$mount_event" == *':ro,nosuid,nodev,noexec' ]] \
    || fail "Production recovery discovery did not request all read-only mount options."
  mountpoint="${mount_event#mount:}"
  mountpoint="${mountpoint%:ro,nosuid,nodev,noexec}"
  grep -Fqx "umount:${mountpoint}" "${case_dir}/mount.log" \
    || fail "Production recovery discovery did not clean its own mount."
  [[ ! -e "$mountpoint" && ! -e "${case_dir}/mount.state" ]] \
    || fail "Production recovery mount cleanup left temporary state behind."
  pass "label/UUID discovery and read-only production mount flow work through mocks"
}

test_existing_production_mount_is_not_cleaned_up() {
  local case_dir local_file
  case_dir="$(new_case existing-production-mount)"
  write_all_recovery_secrets "${case_dir}/recovery/secrets/secrets.env"
  printf '%s\n' "${case_dir}/recovery" > "${case_dir}/mount.state"
  : > "${case_dir}/mount.log"

  NOVA_TEST_USE_PRODUCTION_RECOVERY=1
  NOVA_TEST_MOCK_RECOVERY_SOURCE="${case_dir}/recovery"
  NOVA_TEST_MOCK_MOUNT_STATE="${case_dir}/mount.state"
  NOVA_TEST_MOCK_MOUNT_LOG="${case_dir}/mount.log"
  NOVA_TEST_PATH_OVERRIDE="${REPOSITORY_DIR}/tests/mocks:${PATH}"
  run_phase1 "$case_dir"
  unset NOVA_TEST_USE_PRODUCTION_RECOVERY NOVA_TEST_MOCK_RECOVERY_SOURCE \
    NOVA_TEST_MOCK_MOUNT_STATE NOVA_TEST_MOCK_MOUNT_LOG NOVA_TEST_PATH_OVERRIDE

  local_file="${case_dir}/root/opt/nova-bootstrap/secrets.env"
  assert_file_contains "$local_file" 'TOKEN=TEST_SECRET_TOKEN;$HOME&`not-executed`'
  [[ ! -s "${case_dir}/mount.log" ]] \
    || fail "Existing production recovery mount was mounted or unmounted by Phase 1."
  [[ -f "${case_dir}/mount.state" ]] \
    || fail "Existing production recovery mount state was removed."
  pass "existing label/UUID mount is reused and never cleaned up by Phase 1"
}

test_unsupported_architecture_fails_preflight() {
  local case_dir
  case_dir="$(new_case bad-architecture)"
  NOVA_TEST_ARCH_OVERRIDE=x86_64
  if run_phase1 "$case_dir"; then
    unset NOVA_TEST_ARCH_OVERRIDE
    fail "Unsupported architecture unexpectedly passed preflight."
  fi
  unset NOVA_TEST_ARCH_OVERRIDE
  grep -Fq 'Unsupported architecture' "${case_dir}/output.log" \
    || fail "Unsupported architecture did not have a clear reason."
  [[ ! -e "${case_dir}/root/opt/nova-bootstrap" ]] \
    || fail "Failed preflight changed the target path."
  pass "unsupported architecture fails before system changes"
}

test_unsupported_os_fails_preflight() {
  local case_dir
  case_dir="$(new_case bad-os)"
  printf '%s\n' 'ID=debian' 'VERSION_ID=12' 'VERSION_CODENAME=bookworm' \
    > "${case_dir}/root/etc/os-release"
  if run_phase1 "$case_dir"; then
    fail "Unsupported operating system unexpectedly passed preflight."
  fi
  grep -Fq 'Debian 13 is required' "${case_dir}/output.log" \
    || fail "Unsupported operating system did not have a clear reason."
  [[ ! -e "${case_dir}/root/opt/nova-bootstrap" ]] \
    || fail "Failed operating-system preflight changed the target path."
  pass "unsupported operating system fails before system changes"
}

test_missing_root_privileges_fail_preflight() {
  local case_dir
  case_dir="$(new_case no-root)"
  NOVA_TEST_EUID_OVERRIDE=1000
  if run_phase1 "$case_dir"; then
    unset NOVA_TEST_EUID_OVERRIDE
    fail "Missing root privileges unexpectedly passed preflight."
  fi
  unset NOVA_TEST_EUID_OVERRIDE
  grep -Fq 'must run as root' "${case_dir}/output.log" \
    || fail "Missing root privileges did not have a clear reason."
  [[ ! -e "${case_dir}/root/opt/nova-bootstrap" ]] \
    || fail "Failed privilege preflight changed the target path."
  pass "missing root privileges fail before system changes"
}

test_network_failure_fails_preflight() {
  local case_dir
  case_dir="$(new_case no-network)"
  NOVA_TEST_NETWORK_OVERRIDE=0
  if run_phase1 "$case_dir"; then
    unset NOVA_TEST_NETWORK_OVERRIDE
    fail "Failed basic network check unexpectedly passed preflight."
  fi
  unset NOVA_TEST_NETWORK_OVERRIDE
  grep -Fq 'Basic network reachability check failed' "${case_dir}/output.log" \
    || fail "Failed basic network check did not have a clear reason."
  [[ ! -e "${case_dir}/root/opt/nova-bootstrap" ]] \
    || fail "Failed network preflight changed the target path."
  pass "failed network reachability stops before system changes"
}

test_unsafe_target_fails_preflight() {
  local case_dir
  case_dir="$(new_case unsafe-target)"
  printf '%s\n' 'not-a-directory' > "${case_dir}/root/opt/nova-bootstrap"
  if run_phase1 "$case_dir"; then
    fail "Unsafe target path unexpectedly passed preflight."
  fi
  grep -Fq 'Safe target validation failed' "${case_dir}/output.log" \
    || fail "Unsafe target did not have a clear reason."
  pass "unsafe target paths fail before bootstrap writes"
}

test_unexpected_secret_name_is_rejected() {
  local case_dir
  case_dir="$(new_case unexpected-secret-name)"
  printf '%s\n' 'TOKEN=TEST_SECRET_VALID' 'UNEXPECTED=TEST_SECRET_UNEXPECTED' \
    > "${case_dir}/recovery/secrets/secrets.env"
  if run_phase1 "$case_dir" "${case_dir}/recovery" 0; then
    fail "Unexpected secret variable name was accepted."
  fi
  grep -Fq 'Unexpected variable name in INFRA-RECOVERY secrets file: UNEXPECTED' \
    "${case_dir}/output.log" || fail "Unexpected secret name was not reported safely."
  assert_output_excludes "${case_dir}/output.log" 'TEST_SECRET_UNEXPECTED'
  [[ ! -e "${case_dir}/root/opt/nova-bootstrap" ]] \
    || fail "Invalid recovery input changed the target path."
  grep -q '^umount:' "${case_dir}/events.log" \
    || fail "Installer-created mount was not cleaned after invalid recovery input."
  pass "unexpected secret names are rejected without exposing values"
}

printf 'TAP version 13\n'
test_no_recovery
test_recovery_with_all_secrets
test_missing_recovery_values
test_existing_real_values_are_preserved
test_placeholder_is_replaced
test_conflicting_real_values_fail_safely
test_repeated_execution_is_idempotent
test_resulting_mode_is_0600
test_output_never_contains_values
test_installer_mount_is_cleaned_up
test_production_recovery_discovery_with_mocks
test_existing_production_mount_is_not_cleaned_up
test_unsupported_architecture_fails_preflight
test_unsupported_os_fails_preflight
test_missing_root_privileges_fail_preflight
test_network_failure_fails_preflight
test_unsafe_target_fails_preflight
test_unexpected_secret_name_is_rejected
printf '1..%d\n' "$TESTS_RUN"
