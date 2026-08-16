#!/usr/bin/env bash

# Phase 12: install the managed Docker Compose update helper.

readonly NOVA_PHASE12_SOURCE_RELATIVE_PATH="scripts/dup"
readonly NOVA_PHASE12_TARGET_PATH="/usr/local/bin/dup"

nova_phase12_main() {
  local source_file temporary_file target_dir
  nova_phase1_info "Phase 12 Docker Compose update helper"
  source_file="${NOVA_INSTALLER_DIR}/${NOVA_PHASE12_SOURCE_RELATIVE_PATH}"
  target_dir="$(dirname "$NOVA_PHASE12_TARGET_PATH")"
  if [[ ! -f "$source_file" || -L "$source_file" ]]; then
    nova_phase1_error "Docker update helper source file is missing or unsafe."
    return 1
  fi
  mkdir -p -- "$target_dir"
  temporary_file="$(mktemp "${NOVA_PHASE12_TARGET_PATH}.candidate.XXXXXX")"
  cp -- "$source_file" "$temporary_file"
  chmod 0755 -- "$temporary_file"
  chown root:root -- "$temporary_file"
  if [[ -f "$NOVA_PHASE12_TARGET_PATH" ]] && cmp -s -- "$temporary_file" "$NOVA_PHASE12_TARGET_PATH"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$NOVA_PHASE12_TARGET_PATH"
  fi
  chmod 0755 -- "$NOVA_PHASE12_TARGET_PATH"
  chown root:root -- "$NOVA_PHASE12_TARGET_PATH"
  nova_phase1_ok "Docker update helper installed at ${NOVA_PHASE12_TARGET_PATH}."
}
