#!/usr/bin/env bash

# Phase 1 only: read-only preflight checks, optional INFRA-RECOVERY discovery,
# and conservative bootstrap of /opt/nova-bootstrap/secrets.env.

readonly NOVA_PHASE1_RECOVERY_LABEL="INFRA-RECOVERY"
readonly NOVA_PHASE1_SECRET_RELATIVE_PATH="secrets/secrets.env"
readonly NOVA_PHASE1_LOCAL_SECRET_RELATIVE_PATH="opt/nova-bootstrap/secrets.env"
readonly NOVA_PHASE1_NETWORK_HOST="deb.debian.org"
readonly NOVA_PHASE1_NETWORK_URL="https://deb.debian.org/"
readonly -a NOVA_PHASE1_SECRET_NAMES=(
  "DYNDNS_URL"
  "CAMERA_URL"
  "TOKEN"
  "WG_EASY_PASSWORD"
)

NOVA_PHASE1_ROOT=""
NOVA_PHASE1_RECOVERY_ROOT=""
NOVA_PHASE1_RECOVERY_UUID=""
NOVA_PHASE1_OWNED_MOUNTPOINT=""

nova_phase1_info() {
  printf '[INFO] %s\n' "$*"
}

nova_phase1_ok() {
  printf '[OK] %s\n' "$*"
}

nova_phase1_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

nova_phase1_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

nova_phase1_placeholder_for() {
  printf 'CHANGE_ME_%s' "$1"
}

nova_phase1_is_expected_name() {
  local candidate="$1"
  local expected

  for expected in "${NOVA_PHASE1_SECRET_NAMES[@]}"; do
    if [[ "$candidate" == "$expected" ]]; then
      return 0
    fi
  done

  return 1
}

nova_phase1_is_real_value() {
  local name="$1"
  local value="$2"

  [[ -n "$value" && "$value" != CHANGE_ME_* \
    && "$value" != "$(nova_phase1_placeholder_for "$name")" ]]
}

nova_phase1_configure_paths() {
  NOVA_PHASE1_ROOT=""
}

nova_phase1_root_path() {
  local relative_path="${1#/}"
  printf '%s/%s' "$NOVA_PHASE1_ROOT" "$relative_path"
}

nova_phase1_read_assignment() {
  local file="$1"
  local requested_name="$2"
  local line key value

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || continue

    key="${line%%=*}"
    if [[ "$key" != "$requested_name" ]]; then
      continue
    fi

    value="${line#*=}"
    if (( ${#value} >= 2 )); then
      if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi

    printf '%s' "$value"
    return 0
  done < "$file"

  return 1
}

nova_phase1_require_commands() {
  local -a required_commands
  local command_name
  local missing=0

  required_commands=(
    bash blkid chmod chown cmp curl dirname findmnt getent id mkdir mktemp mount mv
    readlink rm rmdir stat tr umount uname
  )

  for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      nova_phase1_error "Required Phase 1 command is missing: ${command_name}"
      missing=1
    fi
  done

  (( missing == 0 ))
}

nova_phase1_check_os() {
  local os_release os_release_real
  local os_id=""
  local version_id=""
  local version_codename=""
  local debian_codename=""

  os_release="$(nova_phase1_root_path "/etc/os-release")"
  if [[ ! -e "$os_release" ]]; then
    nova_phase1_error "Cannot read /etc/os-release."
    return 1
  fi
  os_release_real="$(readlink -f -- "$os_release")"
  if [[ ! -f "$os_release_real" ]]; then
    nova_phase1_error "Cannot safely resolve /etc/os-release to a regular file."
    return 1
  fi
  if [[ "$os_release_real" != "$(nova_phase1_root_path "/etc/os-release")" \
    && "$os_release_real" != "$(nova_phase1_root_path "/usr/lib/os-release")" ]]; then
    nova_phase1_error "/etc/os-release resolves outside the supported system paths."
    return 1
  fi
  os_release="$os_release_real"

  os_id="$(nova_phase1_read_assignment "$os_release" "ID" || true)"
  version_id="$(nova_phase1_read_assignment "$os_release" "VERSION_ID" || true)"
  version_codename="$(nova_phase1_read_assignment "$os_release" "VERSION_CODENAME" || true)"
  debian_codename="$(nova_phase1_read_assignment "$os_release" "DEBIAN_CODENAME" || true)"

  if [[ "$os_id" != "debian" && "$os_id" != "raspbian" ]]; then
    nova_phase1_error "Unsupported operating system: expected Debian or Raspberry Pi OS based on Debian 13."
    return 1
  fi

  if [[ "$version_id" != "13" ]]; then
    nova_phase1_error "Unsupported operating system version: Debian 13 is required."
    return 1
  fi

  if [[ "$version_codename" != "trixie" && "$debian_codename" != "trixie" ]]; then
    nova_phase1_error "Unsupported Debian release: trixie is required."
    return 1
  fi

  nova_phase1_ok "Operating system is Debian 13 (trixie) or a matching Raspberry Pi OS release."
}

nova_phase1_check_architecture() {
  local architecture

  architecture="$(uname -m)"

  if [[ "$architecture" != "aarch64" && "$architecture" != "arm64" ]]; then
    nova_phase1_error "Unsupported architecture: arm64/aarch64 is required."
    return 1
  fi

  nova_phase1_ok "Architecture is arm64/aarch64."
}

nova_phase1_check_hardware() {
  local model_file model

  model_file="$(nova_phase1_root_path "/proc/device-tree/model")"
  if [[ ! -f "$model_file" || -L "$model_file" ]]; then
    nova_phase1_error "Cannot verify Raspberry Pi hardware from /proc/device-tree/model."
    return 1
  fi

  model="$(tr -d '\000' < "$model_file")"
  if [[ "$model" != *"Raspberry Pi 5"* ]]; then
    nova_phase1_error "Unsupported hardware: Raspberry Pi 5 is required."
    return 1
  fi

  nova_phase1_ok "Hardware is Raspberry Pi 5."
}

nova_phase1_check_privileges() {
  local effective_uid

  effective_uid="$(id -u)"

  if [[ "$effective_uid" != "0" ]]; then
    nova_phase1_error "Phase 1 must run as root; use sudo for the installer."
    return 1
  fi

  nova_phase1_ok "Required root privileges are available."
}

nova_phase1_check_network() {
  if ! getent ahosts "$NOVA_PHASE1_NETWORK_HOST" >/dev/null 2>&1; then
    nova_phase1_error "DNS resolution failed during the read-only network check."
    return 1
  fi
  if ! curl -fsSL --connect-timeout 5 --max-time 15 --output /dev/null "$NOVA_PHASE1_NETWORK_URL"; then
    nova_phase1_error "HTTPS reachability failed during the read-only network check."
    return 1
  fi

  nova_phase1_ok "Basic DNS and HTTPS reachability are available; DNS configuration was not changed."
}

nova_phase1_check_safe_paths() {
  local opt_dir run_dir target_dir target_file

  opt_dir="$(nova_phase1_root_path "/opt")"
  run_dir="$(nova_phase1_root_path "/run")"
  target_dir="$(nova_phase1_root_path "/opt/nova-bootstrap")"
  target_file="$(nova_phase1_root_path "/${NOVA_PHASE1_LOCAL_SECRET_RELATIVE_PATH}")"

  if [[ ! -d "$opt_dir" || -L "$opt_dir" ]]; then
    nova_phase1_error "Safe target validation failed: /opt must be a real directory, not a symlink."
    return 1
  fi

  if [[ ! -d "$run_dir" || -L "$run_dir" ]]; then
    nova_phase1_error "Safe temporary path validation failed: /run must be a real directory, not a symlink."
    return 1
  fi

  if [[ -e "$target_dir" || -L "$target_dir" ]]; then
    if [[ ! -d "$target_dir" || -L "$target_dir" ]]; then
      nova_phase1_error "Safe target validation failed: /opt/nova-bootstrap must be a real directory."
      return 1
    fi
  fi

  if [[ -e "$target_file" || -L "$target_file" ]]; then
    if [[ ! -f "$target_file" || -L "$target_file" ]]; then
      nova_phase1_error "Safe target validation failed: secrets.env must be a regular file, not a symlink."
      return 1
    fi
  fi

  nova_phase1_ok "Target and temporary paths passed conservative safety checks."
}

nova_phase1_preflight() {
  nova_phase1_info "Phase 1 preflight checks"
  nova_phase1_require_commands
  nova_phase1_check_os
  nova_phase1_check_architecture
  nova_phase1_check_hardware
  nova_phase1_check_privileges
  nova_phase1_check_network
  nova_phase1_check_safe_paths
  nova_phase1_ok "All Phase 1 preflight checks passed without changing the system."
}

nova_phase1_find_single_line() {
  local content="$1"
  local result_name="$2"
  local ambiguity_message="$3"
  local line
  local -a lines=()

  while IFS= read -r line; do
    [[ -n "$line" ]] && lines+=("$line")
  done <<< "$content"

  if (( ${#lines[@]} > 1 )); then
    nova_phase1_error "$ambiguity_message"
    return 1
  fi

  printf -v "$result_name" '%s' "${lines[0]:-}"
}

nova_phase1_discover_recovery_production() {
  local devices_output=""
  local device=""
  local filesystem_type=""
  local uuid=""
  local mount_output=""
  local existing_mount=""
  local mounted_uuid=""
  local mounted_type=""
  local mounted_options=""
  local command_status
  local run_dir

  set +e
  devices_output="$(blkid -t "LABEL=${NOVA_PHASE1_RECOVERY_LABEL}" -o device 2>/dev/null)"
  command_status=$?
  set -e

  if (( command_status == 2 )) || [[ -z "$devices_output" ]]; then
    return 0
  fi
  if (( command_status != 0 )); then
    nova_phase1_error "Filesystem-label discovery failed."
    return 1
  fi

  nova_phase1_find_single_line "$devices_output" device \
    "More than one filesystem uses the ${NOVA_PHASE1_RECOVERY_LABEL} label; refusing an ambiguous recovery source."
  [[ -n "$device" ]] || return 0

  filesystem_type="$(blkid -s TYPE -o value -- "$device" 2>/dev/null || true)"
  uuid="$(blkid -s UUID -o value -- "$device" 2>/dev/null || true)"
  if [[ "$filesystem_type" != "ext4" ]]; then
    nova_phase1_error "${NOVA_PHASE1_RECOVERY_LABEL} was found but is not an ext4 filesystem."
    return 1
  fi
  if [[ -z "$uuid" ]]; then
    nova_phase1_error "${NOVA_PHASE1_RECOVERY_LABEL} was found but has no discoverable filesystem UUID."
    return 1
  fi

  set +e
  mount_output="$(findmnt -rn -S "UUID=${uuid}" -o TARGET 2>/dev/null)"
  command_status=$?
  set -e
  if (( command_status != 0 && command_status != 1 )); then
    nova_phase1_error "Unable to determine whether ${NOVA_PHASE1_RECOVERY_LABEL} is already mounted."
    return 1
  fi

  nova_phase1_find_single_line "$mount_output" existing_mount \
    "The recovery filesystem has more than one mount target; refusing an ambiguous existing mount."
  if [[ -n "$existing_mount" ]]; then
    if [[ -L "$existing_mount" ]]; then
      nova_phase1_error "The existing recovery mountpoint is a symlink; refusing to use it."
      return 1
    fi
    existing_mount="$(readlink -f -- "$existing_mount")"
    if [[ -z "$existing_mount" || ! -d "$existing_mount" || -L "$existing_mount" ]]; then
      nova_phase1_error "The existing recovery mountpoint is not a safe real directory."
      return 1
    fi

    mounted_uuid="$(findmnt -rn -M "$existing_mount" -o UUID 2>/dev/null || true)"
    mounted_type="$(findmnt -rn -M "$existing_mount" -o FSTYPE 2>/dev/null || true)"
    mounted_options="$(findmnt -rn -M "$existing_mount" -o OPTIONS 2>/dev/null || true)"
    if [[ "$mounted_uuid" != "$uuid" || "$mounted_type" != "ext4" ]]; then
      nova_phase1_error "The existing recovery mountpoint does not match the discovered ext4 filesystem UUID."
      return 1
    fi

    if [[ ",${mounted_options}," != *,ro,* ]]; then
      nova_phase1_warn "${NOVA_PHASE1_RECOVERY_LABEL} is already mounted read-write by another actor; Phase 1 will only read it."
    fi

    NOVA_PHASE1_RECOVERY_ROOT="$existing_mount"
    NOVA_PHASE1_RECOVERY_UUID="$uuid"
    nova_phase1_ok "Using the existing ${NOVA_PHASE1_RECOVERY_LABEL} mount without changing it."
    return 0
  fi

  run_dir="$(nova_phase1_root_path "/run")"
  NOVA_PHASE1_OWNED_MOUNTPOINT="$(mktemp -d "${run_dir}/nova-infra-recovery.XXXXXX")"
  if ! mount -o ro,nosuid,nodev,noexec -- "$device" "$NOVA_PHASE1_OWNED_MOUNTPOINT"; then
    rmdir -- "$NOVA_PHASE1_OWNED_MOUNTPOINT" 2>/dev/null || true
    NOVA_PHASE1_OWNED_MOUNTPOINT=""
    nova_phase1_error "Unable to mount ${NOVA_PHASE1_RECOVERY_LABEL} read-only."
    return 1
  fi

  mounted_uuid="$(findmnt -rn -M "$NOVA_PHASE1_OWNED_MOUNTPOINT" -o UUID 2>/dev/null || true)"
  mounted_type="$(findmnt -rn -M "$NOVA_PHASE1_OWNED_MOUNTPOINT" -o FSTYPE 2>/dev/null || true)"
  mounted_options="$(findmnt -rn -M "$NOVA_PHASE1_OWNED_MOUNTPOINT" -o OPTIONS 2>/dev/null || true)"
  if [[ "$mounted_uuid" != "$uuid" || "$mounted_type" != "ext4" || ",${mounted_options}," != *,ro,* ]]; then
    nova_phase1_error "The installer-created recovery mount failed UUID, filesystem, or read-only validation."
    return 1
  fi

  NOVA_PHASE1_RECOVERY_ROOT="$NOVA_PHASE1_OWNED_MOUNTPOINT"
  NOVA_PHASE1_RECOVERY_UUID="$uuid"
  nova_phase1_ok "Mounted ${NOVA_PHASE1_RECOVERY_LABEL} read-only at an installer-controlled temporary mountpoint."
}

nova_phase1_discover_recovery() {
  NOVA_PHASE1_RECOVERY_ROOT=""
  NOVA_PHASE1_RECOVERY_UUID=""
  NOVA_PHASE1_OWNED_MOUNTPOINT=""

  nova_phase1_info "Looking for optional ext4 filesystem label ${NOVA_PHASE1_RECOVERY_LABEL}."
  nova_phase1_discover_recovery_production

  if [[ -z "$NOVA_PHASE1_RECOVERY_ROOT" ]]; then
    nova_phase1_warn "${NOVA_PHASE1_RECOVERY_LABEL} was not found; continuing with existing values and placeholders."
  fi
}

nova_phase1_validate_recovery_secret_path() {
  local recovery_file="$1"
  local recovery_root_real file_real mounted_uuid

  if [[ -L "${NOVA_PHASE1_RECOVERY_ROOT}/secrets" || -L "$recovery_file" ]]; then
    nova_phase1_error "Recovery secrets path contains a symlink; refusing to read it."
    return 2
  fi
  if [[ ! -f "$recovery_file" ]]; then
    if [[ -e "$recovery_file" ]]; then
      nova_phase1_error "Recovery secrets path exists but is not a regular file."
      return 2
    fi
    return 1
  fi

  recovery_root_real="$(readlink -f -- "$NOVA_PHASE1_RECOVERY_ROOT")"
  file_real="$(readlink -f -- "$recovery_file")"
  if [[ -z "$recovery_root_real" || "$file_real" != "${recovery_root_real}/${NOVA_PHASE1_SECRET_RELATIVE_PATH}" ]]; then
    nova_phase1_error "Recovery secrets file resolves outside the expected recovery path."
    return 2
  fi

  mounted_uuid="$(findmnt -rn -T "$file_real" -o UUID 2>/dev/null || true)"
  if [[ -z "$mounted_uuid" || "$mounted_uuid" != "$NOVA_PHASE1_RECOVERY_UUID" ]]; then
    nova_phase1_error "Recovery secrets file is not backed by the validated recovery filesystem."
    return 2
  fi

  return 0
}

nova_phase1_parse_secrets_file() {
  local file="$1"
  local source_description="$2"
  local values_name="$3"
  local present_name="$4"
  local -n values_ref="$values_name"
  local -n present_ref="$present_name"
  local line key value first last line_number=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" != *=* ]]; then
      nova_phase1_error "Invalid assignment at line ${line_number} in ${source_description}; no value was displayed."
      return 1
    fi

    key="${line%%=*}"
    value="${line#*=}"
    if [[ "$key" == "ADGUARD_PASSWORD_HASH" ]]; then
      # Deprecated legacy value: AdGuard's authoritative recovery YAML now
      # contains its own password hash. Never copy or display this value.
      continue
    fi
    if ! nova_phase1_is_expected_name "$key"; then
      if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        nova_phase1_error "Unexpected variable name in ${source_description}: ${key}"
      else
        nova_phase1_error "Invalid variable name at line ${line_number} in ${source_description}."
      fi
      return 1
    fi
    if [[ "${present_ref[$key]:-0}" == "1" ]]; then
      nova_phase1_error "Duplicate variable name in ${source_description}: ${key}"
      return 1
    fi

    if (( ${#value} >= 2 )); then
      first="${value:0:1}"
      last="${value: -1}"
      if [[ "$first" == "$last" && ( "$first" == '"' || "$first" == "'" ) ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi

    values_ref["$key"]="$value"
    present_ref["$key"]=1
  done < "$file"
}

nova_phase1_write_secrets() {
  local values_name="$1"
  local -n values_ref="$values_name"
  local target_dir target_file temporary_file name
  local changed=1

  target_dir="$(nova_phase1_root_path "/opt/nova-bootstrap")"
  target_file="$(nova_phase1_root_path "/${NOVA_PHASE1_LOCAL_SECRET_RELATIVE_PATH}")"

  if [[ -e "$target_dir" || -L "$target_dir" ]]; then
    if [[ ! -d "$target_dir" || -L "$target_dir" ]]; then
      nova_phase1_error "Refusing to write through an unsafe /opt/nova-bootstrap path."
      return 1
    fi
  else
    mkdir -- "$target_dir"
  fi
  chmod 0700 -- "$target_dir"

  if [[ -e "$target_file" || -L "$target_file" ]]; then
    if [[ ! -f "$target_file" || -L "$target_file" ]]; then
      nova_phase1_error "Refusing to replace an unsafe secrets.env path."
      return 1
    fi
  fi

  temporary_file="$(mktemp "${target_dir}/.secrets.env.XXXXXX")"
  chmod 0600 -- "$temporary_file"
  for name in "${NOVA_PHASE1_SECRET_NAMES[@]}"; do
    printf '%s=%s\n' "$name" "${values_ref[$name]}" >> "$temporary_file"
  done

  if [[ -f "$target_file" ]] && cmp -s -- "$temporary_file" "$target_file"; then
    changed=0
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$target_file"
  fi

  chmod 0600 -- "$target_file"
  chown root:root -- "$target_dir"
  chown root:root -- "$target_file"

  if (( changed == 1 )); then
    nova_phase1_ok "Updated /opt/nova-bootstrap/secrets.env without displaying secret values."
  else
    nova_phase1_ok "Existing /opt/nova-bootstrap/secrets.env already contains the merged values."
  fi
}

nova_phase1_bootstrap_secrets() {
  local local_file recovery_file=""
  local recovery_status=1
  local name placeholder local_value recovery_value chosen_value
  local -a conflicts=()
  local -a unresolved=()
  declare -A local_values=()
  declare -A local_present=()
  declare -A recovery_values=()
  declare -A recovery_present=()
  declare -A merged_values=()

  local_file="$(nova_phase1_root_path "/${NOVA_PHASE1_LOCAL_SECRET_RELATIVE_PATH}")"
  if [[ -f "$local_file" ]]; then
    nova_phase1_parse_secrets_file "$local_file" "existing local secrets file" local_values local_present
  fi

  if [[ -n "$NOVA_PHASE1_RECOVERY_ROOT" ]]; then
    recovery_file="${NOVA_PHASE1_RECOVERY_ROOT}/${NOVA_PHASE1_SECRET_RELATIVE_PATH}"
    set +e
    nova_phase1_validate_recovery_secret_path "$recovery_file"
    recovery_status=$?
    set -e
    if (( recovery_status == 0 )); then
      nova_phase1_parse_secrets_file "$recovery_file" "INFRA-RECOVERY secrets file" recovery_values recovery_present
      nova_phase1_ok "Read expected secret assignments from ${NOVA_PHASE1_RECOVERY_LABEL} without displaying values."
    elif (( recovery_status == 1 )); then
      nova_phase1_warn "${NOVA_PHASE1_RECOVERY_LABEL} does not contain /secrets/secrets.env; continuing with existing values and placeholders."
    else
      return 1
    fi
  fi

  for name in "${NOVA_PHASE1_SECRET_NAMES[@]}"; do
    placeholder="$(nova_phase1_placeholder_for "$name")"
    local_value="${local_values[$name]:-}"
    recovery_value="${recovery_values[$name]:-}"
    chosen_value="$placeholder"

    if [[ "${local_present[$name]:-0}" == "1" ]] && nova_phase1_is_real_value "$name" "$local_value"; then
      chosen_value="$local_value"
      if [[ "${recovery_present[$name]:-0}" == "1" ]] && nova_phase1_is_real_value "$name" "$recovery_value"; then
        if [[ "$local_value" != "$recovery_value" ]]; then
          conflicts+=("$name")
        fi
      fi
    elif [[ "${recovery_present[$name]:-0}" == "1" ]] && nova_phase1_is_real_value "$name" "$recovery_value"; then
      chosen_value="$recovery_value"
    fi

    merged_values["$name"]="$chosen_value"
    if ! nova_phase1_is_real_value "$name" "$chosen_value"; then
      unresolved+=("$name")
    fi
  done

  if (( ${#conflicts[@]} > 0 )); then
    nova_phase1_error "Conflicting real local and recovery values for: ${conflicts[*]}"
    nova_phase1_error "The existing local secrets file was not changed."
    return 1
  fi

  nova_phase1_write_secrets merged_values

  if (( ${#unresolved[@]} > 0 )); then
    nova_phase1_warn "Unresolved secret variables: ${unresolved[*]}"
  else
    nova_phase1_ok "All expected secret variables are resolved."
  fi
}

nova_phase1_cleanup_recovery() {
  local mountpoint="$NOVA_PHASE1_OWNED_MOUNTPOINT"
  local cleanup_failed=0

  if [[ -z "$mountpoint" ]]; then
    return 0
  fi

  if ! umount -- "$mountpoint"; then
    nova_phase1_error "Could not unmount the installer-created recovery mountpoint."
    cleanup_failed=1
  fi

  if (( cleanup_failed == 0 )); then
    NOVA_PHASE1_OWNED_MOUNTPOINT=""
    NOVA_PHASE1_RECOVERY_ROOT=""
    NOVA_PHASE1_RECOVERY_UUID=""
    if ! rmdir -- "$mountpoint"; then
      nova_phase1_error "Could not remove the installer-created temporary mountpoint."
      cleanup_failed=1
    fi
  fi

  if (( cleanup_failed == 0 )); then
    nova_phase1_ok "Cleaned up the recovery mount created by Phase 1."
  fi

  return "$cleanup_failed"
}

nova_phase1_cleanup_on_exit() {
  local original_status=$?

  if [[ -n "$NOVA_PHASE1_OWNED_MOUNTPOINT" ]]; then
    nova_phase1_cleanup_recovery || true
  fi

  return "$original_status"
}

nova_phase1_main() {
  if (( $# != 0 )); then
    nova_phase1_error "Phase 1 does not accept command-line arguments."
    return 2
  fi

  trap nova_phase1_cleanup_on_exit EXIT
  nova_phase1_configure_paths
  nova_phase1_preflight
  nova_phase1_discover_recovery
  nova_phase1_bootstrap_secrets
  nova_phase1_cleanup_recovery
  trap - EXIT
  nova_phase1_ok "Phase 1 completed. No Phase 2 components were installed or configured."
}
