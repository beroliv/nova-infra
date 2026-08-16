#!/usr/bin/env bash

# Phase 10: install the repository MOTD status script.

readonly NOVA_PHASE10_SOURCE_RELATIVE_PATH="10-infra-status"
readonly NOVA_PHASE10_TARGET_PATH="/etc/update-motd.d/10-infra-status"

nova_phase10_main() {
  local source_file temporary_file target_dir
  source_file="${NOVA_INSTALLER_DIR}/${NOVA_PHASE10_SOURCE_RELATIVE_PATH}"
  target_dir="$(dirname "$NOVA_PHASE10_TARGET_PATH")"
  if [[ ! -f "$source_file" || -L "$source_file" ]]; then
    nova_phase1_error "MOTD source file is missing or unsafe."
    return 1
  fi
  mkdir -p -- "$target_dir"
  temporary_file="$(mktemp "${NOVA_PHASE10_TARGET_PATH}.candidate.XXXXXX")"
  cp -- "$source_file" "$temporary_file"
  chmod 0755 -- "$temporary_file"
  chown root:root -- "$temporary_file"
  if [[ -f "$NOVA_PHASE10_TARGET_PATH" ]] && cmp -s -- "$temporary_file" "$NOVA_PHASE10_TARGET_PATH"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$NOVA_PHASE10_TARGET_PATH"
  fi
  chmod 0755 -- "$NOVA_PHASE10_TARGET_PATH"
  chown root:root -- "$NOVA_PHASE10_TARGET_PATH"
  nova_phase1_ok "Infrastructure MOTD installed at ${NOVA_PHASE10_TARGET_PATH}."
}
