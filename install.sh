#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly NOVA_BOOTSTRAP_CHECKOUT="/home/admin/nova-infra"
readonly NOVA_BOOTSTRAP_REPOSITORY="https://github.com/beroliv/nova-infra.git"

nova_bootstrap_checkout() {
  local checkout="$NOVA_BOOTSTRAP_CHECKOUT"
  local branch remote dirty

  if [[ "$(id -u)" != "0" ]]; then
    printf '[ERROR] Curl bootstrap must run as root; use sudo.\n' >&2
    exit 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    if ! command -v apt-get >/dev/null 2>&1; then
      printf '[ERROR] Git is missing and apt-get is unavailable for bootstrap installation.\n' >&2
      exit 1
    fi
    printf '[INFO] Git is missing; installing it with the standard APT mechanism.\n'
    if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
      printf '[ERROR] Could not update APT metadata for the bootstrap Git installation.\n' >&2
      exit 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y git; then
      printf '[ERROR] Could not install Git for the bootstrap checkout.\n' >&2
      exit 1
    fi
    if ! command -v git >/dev/null 2>&1; then
      printf '[ERROR] Git is still unavailable after bootstrap installation.\n' >&2
      exit 1
    fi
  fi
  if [[ -L "$checkout" || ( -e "$checkout" && ! -d "$checkout" ) ]]; then
    printf '[ERROR] Bootstrap checkout path is not a safe directory: %s\n' "$checkout" >&2
    exit 1
  fi

  if [[ ! -d "$checkout/.git" ]]; then
    if [[ -e "$checkout" ]] && [[ -n "$(find "$checkout" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      printf '[ERROR] Bootstrap checkout exists but is not a Git checkout: %s\n' "$checkout" >&2
      exit 1
    fi
    install -d -o admin -g admin "$checkout"
    if ! runuser -u admin -- git clone --branch main --single-branch "$NOVA_BOOTSTRAP_REPOSITORY" "$checkout"; then
      printf '[ERROR] Could not clone nova-infra into %s.\n' "$checkout" >&2
      exit 1
    fi
  else
    chown --no-dereference admin:admin "$checkout" "$checkout/.git"
    remote="$(runuser -u admin -- git -C "$checkout" remote get-url origin 2>/dev/null || true)"
    if [[ "$remote" != "$NOVA_BOOTSTRAP_REPOSITORY" ]]; then
      printf '[ERROR] Existing bootstrap checkout has an unexpected origin.\n' >&2
      exit 1
    fi
    dirty="$(runuser -u admin -- git -C "$checkout" status --porcelain)"
    if [[ -n "$dirty" ]]; then
      printf '[ERROR] Existing bootstrap checkout has uncommitted changes; refusing to overwrite them.\n' >&2
      exit 1
    fi
    branch="$(runuser -u admin -- git -C "$checkout" branch --show-current)"
    if [[ "$branch" != "main" ]]; then
      printf '[ERROR] Existing bootstrap checkout is not on the main branch.\n' >&2
      exit 1
    fi
    if ! runuser -u admin -- git -C "$checkout" fetch origin main \
      || ! runuser -u admin -- git -C "$checkout" merge --ff-only origin/main; then
      printf '[ERROR] Could not update the persistent nova-infra checkout safely.\n' >&2
      exit 1
    fi
  fi
}

if [[ "${NOVA_CURL_BOOTSTRAP_ACTIVE:-0}" != "1" ]]; then
  NOVA_ENTRYPOINT="${BASH_SOURCE[0]:-}"
  if [[ -z "$NOVA_ENTRYPOINT" || "$NOVA_ENTRYPOINT" == "/dev/stdin" || "$NOVA_ENTRYPOINT" == "bash" || ! -f "$NOVA_ENTRYPOINT" ]]; then
    nova_bootstrap_checkout
    exec env NOVA_CURL_BOOTSTRAP_ACTIVE=1 bash "$NOVA_BOOTSTRAP_CHECKOUT/install.sh" "$@"
  fi
fi

readonly NOVA_INSTALLER_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/phase1.sh
source "${NOVA_INSTALLER_DIR}/lib/phase1.sh"
# shellcheck source=lib/phase2.sh
source "${NOVA_INSTALLER_DIR}/lib/phase2.sh"
# shellcheck source=lib/phase3.sh
source "${NOVA_INSTALLER_DIR}/lib/phase3.sh"
# shellcheck source=lib/phase4a.sh
source "${NOVA_INSTALLER_DIR}/lib/phase4a.sh"
# shellcheck source=lib/phase4b.sh
source "${NOVA_INSTALLER_DIR}/lib/phase4b.sh"
# shellcheck source=lib/phase4c.sh
source "${NOVA_INSTALLER_DIR}/lib/phase4c.sh"
# shellcheck source=lib/phase5.sh
source "${NOVA_INSTALLER_DIR}/lib/phase5.sh"
# shellcheck source=lib/phase6.sh
source "${NOVA_INSTALLER_DIR}/lib/phase6.sh"
# shellcheck source=lib/phase7.sh
source "${NOVA_INSTALLER_DIR}/lib/phase7.sh"
# shellcheck source=lib/phase8.sh
source "${NOVA_INSTALLER_DIR}/lib/phase8.sh"
# shellcheck source=lib/phase9.sh
source "${NOVA_INSTALLER_DIR}/lib/phase9.sh"
# shellcheck source=lib/phase10.sh
source "${NOVA_INSTALLER_DIR}/lib/phase10.sh"
# shellcheck source=lib/phase11.sh
source "${NOVA_INSTALLER_DIR}/lib/phase11.sh"
# shellcheck source=lib/phase12.sh
source "${NOVA_INSTALLER_DIR}/lib/phase12.sh"
# shellcheck source=lib/phase13.sh
source "${NOVA_INSTALLER_DIR}/lib/phase13.sh"

readonly NOVA_INSTALL_PHASES="${NOVA_INSTALL_PHASES:-13}"
if [[ "$NOVA_INSTALL_PHASES" != "1" \
  && "$NOVA_INSTALL_PHASES" != "2" \
  && "$NOVA_INSTALL_PHASES" != "3" \
  && "$NOVA_INSTALL_PHASES" != "4a" \
  && "$NOVA_INSTALL_PHASES" != "4b" \
  && "$NOVA_INSTALL_PHASES" != "4c" \
  && "$NOVA_INSTALL_PHASES" != "5" \
  && "$NOVA_INSTALL_PHASES" != "6" \
  && "$NOVA_INSTALL_PHASES" != "7" \
  && "$NOVA_INSTALL_PHASES" != "8" \
  && "$NOVA_INSTALL_PHASES" != "9" \
  && "$NOVA_INSTALL_PHASES" != "10" \
  && "$NOVA_INSTALL_PHASES" != "11" \
  && "$NOVA_INSTALL_PHASES" != "12" \
  && "$NOVA_INSTALL_PHASES" != "13" ]]; then
  nova_phase1_error "NOVA_INSTALL_PHASES must be 1, 2, 3, 4a, 4b, 4c, 5, 6, 7, 8, 9, 10, 11, 12, or 13."
  exit 2
fi

nova_phase1_main "$@"
if [[ "$NOVA_INSTALL_PHASES" == "2" \
  || "$NOVA_INSTALL_PHASES" == "3" \
  || "$NOVA_INSTALL_PHASES" == "4a" \
  || "$NOVA_INSTALL_PHASES" == "4b" \
  || "$NOVA_INSTALL_PHASES" == "4c" \
  || "$NOVA_INSTALL_PHASES" == "5" \
  || "$NOVA_INSTALL_PHASES" == "6" \
  || "$NOVA_INSTALL_PHASES" == "7" \
  || "$NOVA_INSTALL_PHASES" == "8" \
  || "$NOVA_INSTALL_PHASES" == "9" \
  || "$NOVA_INSTALL_PHASES" == "10" \
  || "$NOVA_INSTALL_PHASES" == "11" \
  || "$NOVA_INSTALL_PHASES" == "12" \
  || "$NOVA_INSTALL_PHASES" == "13" ]]; then
  nova_phase2_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "3" \
  || "$NOVA_INSTALL_PHASES" == "4a" \
  || "$NOVA_INSTALL_PHASES" == "4b" \
  || "$NOVA_INSTALL_PHASES" == "4c" \
  || "$NOVA_INSTALL_PHASES" == "5" \
  || "$NOVA_INSTALL_PHASES" == "6" \
  || "$NOVA_INSTALL_PHASES" == "7" \
  || "$NOVA_INSTALL_PHASES" == "8" \
  || "$NOVA_INSTALL_PHASES" == "9" \
  || "$NOVA_INSTALL_PHASES" == "10" \
  || "$NOVA_INSTALL_PHASES" == "11" \
  || "$NOVA_INSTALL_PHASES" == "12" \
  || "$NOVA_INSTALL_PHASES" == "13" ]]; then
  nova_phase3_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "4a" \
  || "$NOVA_INSTALL_PHASES" == "4b" \
  || "$NOVA_INSTALL_PHASES" == "4c" \
  || "$NOVA_INSTALL_PHASES" == "5" \
  || "$NOVA_INSTALL_PHASES" == "6" \
  || "$NOVA_INSTALL_PHASES" == "7" \
  || "$NOVA_INSTALL_PHASES" == "8" \
  || "$NOVA_INSTALL_PHASES" == "9" \
  || "$NOVA_INSTALL_PHASES" == "10" \
  || "$NOVA_INSTALL_PHASES" == "11" \
  || "$NOVA_INSTALL_PHASES" == "12" \
  || "$NOVA_INSTALL_PHASES" == "13" ]]; then
  nova_phase4a_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "4b" || "$NOVA_INSTALL_PHASES" == "4c" || "$NOVA_INSTALL_PHASES" == "5" || "$NOVA_INSTALL_PHASES" == "6" || "$NOVA_INSTALL_PHASES" == "7" || "$NOVA_INSTALL_PHASES" == "8" || "$NOVA_INSTALL_PHASES" == "9" || "$NOVA_INSTALL_PHASES" == "10" || "$NOVA_INSTALL_PHASES" == "11" || "$NOVA_INSTALL_PHASES" == "12" || "$NOVA_INSTALL_PHASES" == "13" ]]; then
  nova_phase4b_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "4c" || "$NOVA_INSTALL_PHASES" == "5" || "$NOVA_INSTALL_PHASES" == "6" || "$NOVA_INSTALL_PHASES" == "7" || "$NOVA_INSTALL_PHASES" == "8" || "$NOVA_INSTALL_PHASES" == "9" || "$NOVA_INSTALL_PHASES" == "10" || "$NOVA_INSTALL_PHASES" == "11" || "$NOVA_INSTALL_PHASES" == "12" || "$NOVA_INSTALL_PHASES" == "13" ]]; then
  nova_phase4c_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "5" ]]; then
  nova_phase5_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "6" ]]; then
  nova_phase5_main
  nova_phase6_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "7" || "$NOVA_INSTALL_PHASES" == "8" || "$NOVA_INSTALL_PHASES" == "9" || "$NOVA_INSTALL_PHASES" == "10" || "$NOVA_INSTALL_PHASES" == "11" || "$NOVA_INSTALL_PHASES" == "12" || "$NOVA_INSTALL_PHASES" == "13" ]]; then
  nova_phase5_main
  nova_phase6_main
  nova_phase7_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "8" || "$NOVA_INSTALL_PHASES" == "9" || "$NOVA_INSTALL_PHASES" == "10" || "$NOVA_INSTALL_PHASES" == "11" || "$NOVA_INSTALL_PHASES" == "12" || "$NOVA_INSTALL_PHASES" == "13" ]]; then
  nova_phase8_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "9" || "$NOVA_INSTALL_PHASES" == "10" || "$NOVA_INSTALL_PHASES" == "11" || "$NOVA_INSTALL_PHASES" == "12" || "$NOVA_INSTALL_PHASES" == "13" ]]; then
  nova_phase9_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "10" || "$NOVA_INSTALL_PHASES" == "11" || "$NOVA_INSTALL_PHASES" == "12" || "$NOVA_INSTALL_PHASES" == "13" ]]; then
  nova_phase10_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "11" || "$NOVA_INSTALL_PHASES" == "12" || "$NOVA_INSTALL_PHASES" == "13" ]]; then
  nova_phase11_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "12" || "$NOVA_INSTALL_PHASES" == "13" ]]; then
  nova_phase12_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "13" ]]; then
  nova_phase13_main
fi
