#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE="$ROOT_DIR/lib/phase13.sh"

grep -Fq 'NOVA_PHASE13_HUSHLOGIN="/home/admin/.hushlogin"' "$PHASE"
grep -Fq 'chown admin:admin -- "$NOVA_PHASE13_HUSHLOGIN"' "$PHASE"
grep -Fq 'cmp -s -- "$temporary_file" "$bashrc"' "$PHASE"
grep -Fq "alias motd='/usr/local/bin/motd'" "$PHASE"
grep -Fq 'run-parts /etc/update-motd.d/' "$PHASE"
grep -Fq 'if [[ $- == *i* ]]; then' "$PHASE"
grep -Fq '/usr/local/bin/motd' "$PHASE"
grep -Fq 'Der Benutzer admin wurde zur Docker-Gruppe hinzugefügt.' "$PHASE"
grep -Fq 'wifi-check.sh' "$PHASE"
if grep -Eq 'update-motd\.d.*(disable|rm -rf)|rm -rf.*/etc/update-motd\.d' "$PHASE"; then
  printf '%s\n' 'Phase 13 must not disable the complete MOTD framework.' >&2
  exit 1
fi

printf '%s\n' 'Phase 13 login usability checks passed.'
