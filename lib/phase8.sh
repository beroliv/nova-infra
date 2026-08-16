#!/usr/bin/env bash

# Phase 8: restore the existing native Syncthing identity and configuration.

readonly NOVA_PHASE8_PACKAGE="syncthing"
readonly NOVA_PHASE8_USER="admin"
readonly NOVA_PHASE8_STATE_RELATIVE_PATH="home/admin/.local/state/syncthing"
readonly NOVA_PHASE8_BACKUP_RELATIVE_PATH="opt/vaultwarden/backups"
readonly NOVA_PHASE8_SERVICE="syncthing@admin.service"

nova_phase8_require_commands() {
  local command_name missing=0
  for command_name in apt-get awk chmod chown cp dpkg-query grep id mkdir mktemp mv stat systemctl usermod; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      nova_phase1_error "Required Syncthing command is missing: ${command_name}"
      missing=1
    fi
  done
  (( missing == 0 ))
}

nova_phase8_install_package() {
  # Keep the templated service stopped while the package is installed so it
  # cannot create a new identity before the recovery files are restored.
  systemctl stop "$NOVA_PHASE8_SERVICE" >/dev/null 2>&1 || true
  nova_phase1_info "Installing Syncthing from the configured official APT repository."
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -- "$NOVA_PHASE8_PACKAGE"; then
    nova_phase1_error "Syncthing package installation failed."
    return 1
  fi
  if ! dpkg-query -W -f='${Status}' "$NOVA_PHASE8_PACKAGE" 2>/dev/null | grep -Fq 'install ok installed'; then
    nova_phase1_error "Syncthing package is not installed."
    return 1
  fi
}

nova_phase8_state_paths() {
  NOVA_PHASE8_STATE_DIR="$(nova_phase1_root_path "/${NOVA_PHASE8_STATE_RELATIVE_PATH}")"
  NOVA_PHASE8_CERT="${NOVA_PHASE8_STATE_DIR}/cert.pem"
  NOVA_PHASE8_KEY="${NOVA_PHASE8_STATE_DIR}/key.pem"
  NOVA_PHASE8_CONFIG="${NOVA_PHASE8_STATE_DIR}/config.xml"
}

nova_phase8_regular_file() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" && -s "$file" ]]
}

nova_phase8_restore_config() {
  local source_config="$1" temporary_config
  temporary_config="$(mktemp "${NOVA_PHASE8_STATE_DIR}/.config.xml.XXXXXX")"
  if ! awk '
    BEGIN { in_folder=0; folder_id=0; folder_label=0; folder_path=0; identified=0 }
    /<folder([[:space:]>]|$)/ {
      in_folder=1
      folder_id=0
      folder_label=0
      folder_path=0
      if ($0 ~ /id="ycffz-zhzw9"/) folder_id=1
      if ($0 ~ /label="Vaultwarden"/) folder_label=1
      if ($0 ~ /path="~\/backups\/vaultwarden"/ || $0 ~ /path="\/opt\/vaultwarden\/backups"/) {
        sub(/path="[^"]*"/, "path=\"/opt/vaultwarden/backups\"")
        folder_path=1
      }
    }
    in_folder && /<id>ycffz-zhzw9<\/id>/ { folder_id=1 }
    in_folder && /<label>Vaultwarden<\/label>/ { folder_label=1 }
    in_folder && /<path>/ && ($0 ~ /<path>~\/backups\/vaultwarden<\/path>/ || $0 ~ /<path>\/opt\/vaultwarden\/backups<\/path>/) {
      sub(/<path>[^<]*<\/path>/, "<path>/opt/vaultwarden/backups</path>")
      folder_path=1
    }
    { print }
    /<\/folder>/ {
      if (folder_id && folder_label && folder_path) identified++
      in_folder=0
    }
    END { if (identified != 1) exit 42 }
  ' "$source_config" >"$temporary_config"; then
    rm -f -- "$temporary_config"
    nova_phase1_error "Restored Syncthing config did not contain exactly one identifiable Vaultwarden folder."
    return 1
  fi
  chmod 0600 -- "$temporary_config"
  chown "${NOVA_PHASE8_USER}:${NOVA_PHASE8_USER}" -- "$temporary_config"
  mv -f -- "$temporary_config" "$NOVA_PHASE8_CONFIG"
}

nova_phase8_restore_state() {
  local recovery_dir
  local local_cert=0 local_key=0 local_config=0
  nova_phase8_regular_file "$NOVA_PHASE8_CERT" && local_cert=1
  nova_phase8_regular_file "$NOVA_PHASE8_KEY" && local_key=1
  nova_phase8_regular_file "$NOVA_PHASE8_CONFIG" && local_config=1

  if (( local_cert == 1 && local_key == 1 && local_config == 1 )); then
    nova_phase1_ok "Existing Syncthing identity and configuration preserved."
    return 0
  fi
  if (( local_cert != local_key )); then
    nova_phase1_error "Syncthing state contains only one identity file; refusing to replace it automatically."
    return 1
  fi

  nova_phase1_discover_recovery
  if [[ -z "$NOVA_PHASE1_RECOVERY_ROOT" ]]; then
    nova_phase1_error "Syncthing identity/configuration is incomplete and INFRA-RECOVERY is unavailable."
    nova_phase1_cleanup_recovery || true
    return 1
  fi
  recovery_dir="${NOVA_PHASE1_RECOVERY_ROOT}/backup/syncthing"
  if ! nova_phase8_regular_file "${recovery_dir}/cert.pem" \
    || ! nova_phase8_regular_file "${recovery_dir}/key.pem" \
    || ! nova_phase8_regular_file "${recovery_dir}/config.xml"; then
    nova_phase1_error "INFRA-RECOVERY is missing one or more Syncthing restore files."
    nova_phase1_cleanup_recovery || true
    return 1
  fi

  if (( local_cert == 0 )); then
    cp -- "${recovery_dir}/cert.pem" "$NOVA_PHASE8_CERT"
    cp -- "${recovery_dir}/key.pem" "$NOVA_PHASE8_KEY"
  fi
  if (( local_config == 0 )); then
    nova_phase8_restore_config "${recovery_dir}/config.xml" || {
      nova_phase1_cleanup_recovery || true
      return 1
    }
  fi
  chmod 0600 -- "$NOVA_PHASE8_CERT" "$NOVA_PHASE8_KEY" "$NOVA_PHASE8_CONFIG"
  chown "${NOVA_PHASE8_USER}:${NOVA_PHASE8_USER}" -- \
    "$NOVA_PHASE8_CERT" "$NOVA_PHASE8_KEY" "$NOVA_PHASE8_CONFIG"
  nova_phase1_cleanup_recovery || return 1
  nova_phase1_ok "Syncthing identity restored without generating a new Device ID."
}

nova_phase8_prepare_backup_access() {
  local backup_dir group permissions members
  backup_dir="$(nova_phase1_root_path "/${NOVA_PHASE8_BACKUP_RELATIVE_PATH}")"
  if [[ ! -d "$backup_dir" || -L "$backup_dir" ]]; then
    nova_phase1_error "Vaultwarden backup directory is unavailable: /opt/vaultwarden/backups"
    return 1
  fi
  group="$(stat -c '%G' -- "$backup_dir")"
  permissions="$(stat -c '%A' -- "$backup_dir")"
  if [[ -z "$group" || "$group" == "root" || "${permissions:4:1}" != "r" || "${permissions:6:1}" != "x" ]]; then
    nova_phase1_error "Vaultwarden backup directory does not expose safe group read/execute access for admin."
    return 1
  fi
  members="$(id -nG "$NOVA_PHASE8_USER")"
  if ! grep -Eq "(^|[[:space:]])${group}([[:space:]]|$)" <<<"$members"; then
    usermod -aG "$group" "$NOVA_PHASE8_USER"
    nova_phase1_warn "Added admin to the Vaultwarden backup group; a new login/session is required."
  fi
}

nova_phase8_main() {
  nova_phase1_info "Phase 8 Syncthing migration"
  nova_phase8_require_commands
  nova_phase8_install_package
  nova_phase8_state_paths
  systemctl stop "$NOVA_PHASE8_SERVICE" >/dev/null 2>&1 || true
  mkdir -p -- "$NOVA_PHASE8_STATE_DIR"
  chown "${NOVA_PHASE8_USER}:${NOVA_PHASE8_USER}" -- "$NOVA_PHASE8_STATE_DIR"
  chmod 0700 -- "$NOVA_PHASE8_STATE_DIR"
  nova_phase8_restore_state
  nova_phase8_prepare_backup_access
  systemctl enable --now "$NOVA_PHASE8_SERVICE"
  nova_phase1_ok "Syncthing is enabled and started as syncthing@admin.service."
}
