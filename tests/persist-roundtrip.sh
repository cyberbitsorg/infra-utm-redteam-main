#!/usr/bin/env bash
# Unit test: the persistence decision — create the data disk only when absent,
# reuse it when present (so make destroy + up preserves work).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source scripts/persist-lib.sh

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fail=1; fi; }

check "absent disk -> create" "create" "$(persist_action 0)"
check "present disk -> reuse" "reuse"  "$(persist_action 1)"

exit "$fail"
