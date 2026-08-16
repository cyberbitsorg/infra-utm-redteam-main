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
unset DISPLAY_RESOLUTION
check "resolution default" "1920x1080" "$(display_resolution)"
check "resolution default is not dynamic" "false" "$(display_dynamic)"

DISPLAY_RESOLUTION=1280x1024
check "explicit resolution" "1280x1024" "$(display_resolution)"

DISPLAY_RESOLUTION=dynamic
check "dynamic pins nothing" "" "$(display_resolution)"
check "dynamic flag" "true" "$(display_dynamic)"

DISPLAY_RESOLUTION=1920X1080  # capital X
rejects "capital-X resolution" display_resolution
DISPLAY_RESOLUTION=huge
rejects "junk resolution" display_resolution
DISPLAY_RESOLUTION=1920x1080

# --- Booleans emitted for Ansible -------------------------------------------
for v in yes true 1; do
  DESKTOP_COMPOSITING="$v"; check "compositing $v" "true" "$(desktop_compositing)"
  KEEP_HOME="$v";           check "keep_home $v"   "true" "$(keep_home)"
  AUDIO="$v";               check "audio $v"       "true" "$(audio_enabled)"
done
for v in no false 0; do
  DESKTOP_COMPOSITING="$v"; check "compositing $v" "false" "$(desktop_compositing)"
  KEEP_HOME="$v";           check "keep_home $v"   "false" "$(keep_home)"
  AUDIO="$v";               check "audio $v"       "false" "$(audio_enabled)"
done
DESKTOP_COMPOSITING=maybe; rejects "junk DESKTOP_COMPOSITING" desktop_compositing
KEEP_HOME=maybe;           rejects "junk KEEP_HOME" keep_home
AUDIO=maybe;               rejects "junk AUDIO" audio_enabled

# Unset means off: the guest half is pointless until the card is added in UTM.
unset AUDIO; check "audio defaults to off" "false" "$(audio_enabled)"

# --- SHARED_DIR: the basename becomes a guest mount point and an fstab entry -
SHARED_DIR="${HOME}/Sandbox"
check "share name from path" "Sandbox" "$(shared_name)"
SHARED_DIR="/tmp/Red Team"
check "share name keeps the space for preflight to reject" "Red Team" "$(shared_name)"

exit "$fail"
