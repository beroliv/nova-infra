#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

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

readonly NOVA_INSTALL_PHASES="${NOVA_INSTALL_PHASES:-9}"
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
  && "$NOVA_INSTALL_PHASES" != "9" ]]; then
  nova_phase1_error "NOVA_INSTALL_PHASES must be 1, 2, 3, 4a, 4b, 4c, 5, 6, 7, 8, or 9."
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
  || "$NOVA_INSTALL_PHASES" == "9" ]]; then
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
  || "$NOVA_INSTALL_PHASES" == "9" ]]; then
  nova_phase3_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "4a" \
  || "$NOVA_INSTALL_PHASES" == "4b" \
  || "$NOVA_INSTALL_PHASES" == "4c" \
  || "$NOVA_INSTALL_PHASES" == "5" \
  || "$NOVA_INSTALL_PHASES" == "6" \
  || "$NOVA_INSTALL_PHASES" == "7" \
  || "$NOVA_INSTALL_PHASES" == "8" \
  || "$NOVA_INSTALL_PHASES" == "9" ]]; then
  nova_phase4a_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "4b" || "$NOVA_INSTALL_PHASES" == "4c" || "$NOVA_INSTALL_PHASES" == "5" || "$NOVA_INSTALL_PHASES" == "6" || "$NOVA_INSTALL_PHASES" == "7" || "$NOVA_INSTALL_PHASES" == "8" || "$NOVA_INSTALL_PHASES" == "9" ]]; then
  nova_phase4b_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "4c" || "$NOVA_INSTALL_PHASES" == "5" || "$NOVA_INSTALL_PHASES" == "6" || "$NOVA_INSTALL_PHASES" == "7" || "$NOVA_INSTALL_PHASES" == "8" || "$NOVA_INSTALL_PHASES" == "9" ]]; then
  nova_phase4c_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "5" ]]; then
  nova_phase5_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "6" ]]; then
  nova_phase5_main
  nova_phase6_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "7" || "$NOVA_INSTALL_PHASES" == "8" || "$NOVA_INSTALL_PHASES" == "9" ]]; then
  nova_phase5_main
  nova_phase6_main
  nova_phase7_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "8" ]]; then
  nova_phase8_main
fi
if [[ "$NOVA_INSTALL_PHASES" == "9" ]]; then
  nova_phase9_main
fi
