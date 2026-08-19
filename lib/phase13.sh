#!/usr/bin/env bash

# Phase 13: install the admin MOTD convenience alias.

readonly NOVA_PHASE13_BASHRC="/home/admin/.bashrc"
readonly NOVA_PHASE13_ALIAS="alias motd='sudo run-parts /etc/update-motd.d/'"

nova_phase13_main() {
  local bashrc temporary_file
  nova_phase1_info "Phase 13 MOTD convenience alias"
  bashrc="$NOVA_PHASE13_BASHRC"
  if [[ -L "$bashrc" || ( -e "$bashrc" && ! -f "$bashrc" ) ]]; then
    nova_phase1_error "admin .bashrc is not a safe regular file."
    return 1
  fi
  temporary_file="$(mktemp "${bashrc}.candidate.XXXXXX")"
  if [[ -f "$bashrc" ]]; then
    awk -v alias_line="$NOVA_PHASE13_ALIAS" '
      $0 == alias_line { next }
      { print }
      END { print alias_line }
    ' "$bashrc" >"$temporary_file"
  else
    printf '%s\n' "$NOVA_PHASE13_ALIAS" >"$temporary_file"
  fi
  chmod 0644 -- "$temporary_file"
  chown admin:admin -- "$temporary_file"
  if [[ -f "$bashrc" ]] && cmp -s -- "$temporary_file" "$bashrc"; then
    rm -f -- "$temporary_file"
  else
    mv -f -- "$temporary_file" "$bashrc"
  fi
  chmod 0644 -- "$bashrc"
  chown admin:admin -- "$bashrc"
  nova_phase1_ok "The admin MOTD alias is present exactly once in ${bashrc}."
}
