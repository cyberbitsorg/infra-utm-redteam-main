#!/usr/bin/env bash
# Unit test: the lab.conf validators in lib.sh. Every one of these guards a
# value that would otherwise fail deep inside Ansible or UTM instead of at
# preflight, so a typo has to exit non-zero here.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source scripts/lib.sh

fail=0
check() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fail=1; fi
}
rejects() { # <desc> <command...>
  local desc="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then echo "FAIL: $desc accepted"; fail=1; else echo "ok: $desc rejected"; fi
}

# --- DISPLAY_RESOLUTION: a WxH is pinned, 'dynamic' pins nothing -------------
# The value is a list. The first mode is what Xorg prefers at boot; the rest are
# switchable in the guest with lab-screen.
unset DISPLAY_RESOLUTION
check "resolution default" "1920x1080" "$(display_resolution)"
check "resolution default is not dynamic" "false" "$(display_dynamic)"
check "resolution default lists one mode" "1920x1080" "$(display_modes)"

DISPLAY_RESOLUTION=1280x1024
check "explicit resolution" "1280x1024" "$(display_resolution)"
check "one mode is a one-item list" "1280x1024" "$(display_modes)"

DISPLAY_RESOLUTION="3360x1418 1512x982"
check "first mode is the preferred one" "3360x1418" "$(display_resolution)"
check "modes are comma separated for Ansible" "3360x1418,1512x982" "$(display_modes)"
check "a mode list is not dynamic" "false" "$(display_dynamic)"

DISPLAY_RESOLUTION=dynamic
check "dynamic pins nothing" "" "$(display_resolution)"
check "dynamic lists no modes" "" "$(display_modes)"
check "dynamic flag" "true" "$(display_dynamic)"

DISPLAY_RESOLUTION=1920X1080  # capital X
rejects "capital-X resolution" display_resolution
DISPLAY_RESOLUTION=huge
rejects "junk resolution" display_resolution
DISPLAY_RESOLUTION="1920x1080 huge"
rejects "junk later in the list" display_modes
rejects "junk later in the list, via the preferred mode" display_resolution
DISPLAY_RESOLUTION="dynamic 1920x1080"
rejects "dynamic mixed with a mode" display_modes
DISPLAY_RESOLUTION=1920x1080

# --- Booleans emitted for Ansible -------------------------------------------
for v in yes true 1; do
  DESKTOP_COMPOSITING="$v"; check "compositing $v" "true" "$(desktop_compositing)"
  KEEP_HOME="$v";           check "keep_home $v"   "true" "$(keep_home)"
done
for v in no false 0; do
  DESKTOP_COMPOSITING="$v"; check "compositing $v" "false" "$(desktop_compositing)"
  KEEP_HOME="$v";           check "keep_home $v"   "false" "$(keep_home)"
done
DESKTOP_COMPOSITING=maybe; rejects "junk DESKTOP_COMPOSITING" desktop_compositing
KEEP_HOME=maybe;           rejects "junk KEEP_HOME" keep_home

# --- SHARED_DIR: the basename becomes a guest mount point and an fstab entry -
SHARED_DIR="${HOME}/Sandbox"
check "share name from path" "Sandbox" "$(shared_name)"
SHARED_DIR="/tmp/Red Team"
check "share name keeps the space for preflight to reject" "Red Team" "$(shared_name)"

exit "$fail"
