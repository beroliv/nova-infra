#!/usr/bin/env bash

# Phase 13: install the admin MOTD convenience alias.

readonly NOVA_PHASE13_BASHRC="/home/admin/.bashrc"
readonly NOVA_PHASE13_HUSHLOGIN="/home/admin/.hushlogin"
readonly NOVA_PHASE13_WIFI_CHECK="/etc/profile.d/wifi-check.sh"
readonly NOVA_PHASE13_ALIAS="alias motd='sudo run-parts /etc/update-motd.d/'"

nova_phase13_create_hushlogin() {
  if [[ -L "$NOVA_PHASE13_HUSHLOGIN" || ( -e "$NOVA_PHASE13_HUSHLOGIN" && ! -f "$NOVA_PHASE13_HUSHLOGIN" ) ]]; then
    nova_phase1_error "admin .hushlogin is not a safe regular file."
    return 1
  fi
  if [[ ! -f "$NOVA_PHASE13_HUSHLOGIN" ]]; then
    : >"$NOVA_PHASE13_HUSHLOGIN"
  fi
  chmod 0644 -- "$NOVA_PHASE13_HUSHLOGIN"
  chown admin:admin -- "$NOVA_PHASE13_HUSHLOGIN"
}

nova_phase13_disable_raspberrypi_wifi_warning() {
  local diversion
  if ! command -v dpkg-divert >/dev/null 2>&1; then
    return 0
  fi
  if [[ -f "$NOVA_PHASE13_WIFI_CHECK" ]] && grep -Fq 'Wi-Fi is currently blocked by rfkill' "$NOVA_PHASE13_WIFI_CHECK"; then
    if ! dpkg-divert --list "$NOVA_PHASE13_WIFI_CHECK" | grep -Fq "$NOVA_PHASE13_WIFI_CHECK"; then
      dpkg-divert --local --rename --add "$NOVA_PHASE13_WIFI_CHECK" >/dev/null
    fi
    diversion="${NOVA_PHASE13_WIFI_CHECK}.distrib"
    if [[ -f "$diversion" ]]; then
      : >"$NOVA_PHASE13_WIFI_CHECK"
      chmod 0644 -- "$NOVA_PHASE13_WIFI_CHECK"
      chown root:root -- "$NOVA_PHASE13_WIFI_CHECK"
    fi
  fi
}

nova_phase13_report_docker_relogin() {
  if (( NOVA_PHASE3_ADMIN_GROUP_CHANGED == 1 )); then
    printf '%s\n' \
      '------------------------------------------------------------' \
      'Installation abgeschlossen.' \
      '' \
      'Der Benutzer admin wurde zur Docker-Gruppe hinzugefügt.' \
      'Bitte SSH-Verbindung beenden und neu anmelden, damit die' \
      'neue Gruppenmitgliedschaft wirksam wird.' \
      '------------------------------------------------------------'
  fi
}

nova_phase13_main() {
  local bashrc temporary_file
  nova_phase1_info "Phase 13 MOTD convenience alias"
  nova_phase13_create_hushlogin
  nova_phase13_disable_raspberrypi_wifi_warning
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
  nova_phase13_report_docker_relogin
}
