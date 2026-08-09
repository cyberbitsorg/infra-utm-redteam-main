#!/usr/bin/env bash
# Unit test: mullvad_enabled() validates MULLVAD and emits an Ansible bool.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source scripts/lib.sh

fail=0
check() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fail=1; fi
}

# off unless asked for: this adds a third-party apt repository
unset MULLVAD
check "default off" "false" "$(mullvad_enabled)"

for v in yes true 1; do
  MULLVAD="$v"
  check "MULLVAD=$v is on" "true" "$(mullvad_enabled)"
done

for v in no false 0; do
  MULLVAD="$v"
  check "MULLVAD=$v is off" "false" "$(mullvad_enabled)"
done

# junk exits non-zero rather than silently picking a side
MULLVAD=maybe
if ( mullvad_enabled ) >/dev/null 2>&1; then
  echo "FAIL: junk MULLVAD accepted"; fail=1
else
  echo "ok: junk MULLVAD rejected"
fi

exit "$fail"
