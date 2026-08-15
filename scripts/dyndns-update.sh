#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly DYNDNS_CONFIG_FILE="${NOVA_DYNDNS_CONFIG_FILE:-/etc/nova-infra/dyndns.env}"
DYNDNS_RESPONSE_FILE=""

dyndns_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

cleanup() {
  if [[ -n "$DYNDNS_RESPONSE_FILE" ]]; then
    rm -f -- "$DYNDNS_RESPONSE_FILE"
  fi
}
trap cleanup EXIT

load_dyndns_url() {
  local result_name="$1"
  local line key value first last
  local found=0

  if [[ ! -f "$DYNDNS_CONFIG_FILE" || -L "$DYNDNS_CONFIG_FILE" ]]; then
    dyndns_error "DynDNS runtime configuration is missing or unsafe."
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" != *=* ]]; then
      dyndns_error "DynDNS runtime configuration contains an invalid assignment."
      return 1
    fi

    key="${line%%=*}"
    value="${line#*=}"
    if [[ "$key" != "DYNDNS_URL" || "$found" == "1" ]]; then
      dyndns_error "DynDNS runtime configuration contains unexpected or duplicate variables."
      return 1
    fi

    if (( ${#value} >= 2 )); then
      first="${value:0:1}"
      last="${value: -1}"
      if [[ "$first" == "$last" && ( "$first" == '"' || "$first" == "'" ) ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi
    found=1
  done < "$DYNDNS_CONFIG_FILE"

  if [[ "$found" != "1" || -z "$value" || "$value" == CHANGE_ME_* ]]; then
    dyndns_error "DYNDNS_URL is unresolved; no update was attempted."
    return 1
  fi
  if [[ "$value" != https://* ]]; then
    dyndns_error "DYNDNS_URL must use HTTPS; no update was attempted."
    return 1
  fi

  printf -v "$result_name" '%s' "$value"
}

main() {
  local dyndns_url=""
  local curl_config_url

  load_dyndns_url dyndns_url
  DYNDNS_RESPONSE_FILE="$(mktemp "${TMPDIR:-/tmp}/dyndns-response.XXXXXX")"

  curl_config_url="${dyndns_url//\\/\\\\}"
  curl_config_url="${curl_config_url//\"/\\\"}"
  if ! printf 'url = "%s"\n' "$curl_config_url" \
    | curl -fsS --max-time 15 --config - --output "$DYNDNS_RESPONSE_FILE" 2>/dev/null; then
    dyndns_error "FreeDNS update failed due to an HTTP or network error."
    return 1
  fi

  if grep -Fq 'has not changed' "$DYNDNS_RESPONSE_FILE"; then
    printf '[OK] FreeDNS address has not changed.\n'
  else
    printf '[OK] FreeDNS update completed successfully.\n'
  fi
}

main "$@"
