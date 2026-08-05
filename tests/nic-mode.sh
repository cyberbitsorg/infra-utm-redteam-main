#!/usr/bin/env bash
# Unit test: nic_mode() validates NET_MODE.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source scripts/lib.sh

fail=0
check() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fail=1; fi
}

# default is nat
unset NET_MODE
check "default nat" "nat" "$(nic_mode)"

NET_MODE=nat
check "explicit nat" "nat" "$(nic_mode)"

NET_MODE=bridged
check "bridged" "bridged" "$(nic_mode)"

# junk exits non-zero
NET_MODE=wan
if ( nic_mode ) >/dev/null 2>&1; then echo "FAIL: junk NET_MODE accepted"; fail=1; else echo "ok: junk NET_MODE rejected"; fi

exit "$fail"
