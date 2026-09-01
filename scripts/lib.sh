#!/usr/bin/env bash
# Shared helpers, sourced by every script. Not meant to be run directly.

# Every variable defined here is part of the contract with the scripts that
# source this file, so "unused" below is normal, not drift.
# shellcheck shell=bash
# shellcheck disable=SC2034

set -euo pipefail

# --- Paths ------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES_DIR="${REPO_ROOT}/images"
PERSIST_DIR="${REPO_ROOT}/persist"
GEN_DIR="${REPO_ROOT}/generated"
CLOUDINIT_DIR="${REPO_ROOT}/cloud-init"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
INVENTORY_FILE="${ANSIBLE_DIR}/inventory/hosts.generated.yaml"

# --- Logging ----------------------------------------------------------------
# All four write to stderr, keeping stdout for data only: callers capture that
# stdout ("$(create-vm.sh | tail -1)"), so anything logged there is swallowed by
# the command substitution instead of reaching the terminal.
_c() { printf '\033[%sm' "$1"; }
log()  { printf '%s%s%s %s\n' "$(_c '1;34')" "==>" "$(_c 0)" "$*" >&2; }
ok()   { printf '%s%s%s %s\n' "$(_c '1;32')" " ok" "$(_c 0)" "$*" >&2; }
warn() { printf '%s%s%s %s\n' "$(_c '1;33')" " ! " "$(_c 0)" "$*" >&2; }
die()  { printf '%s%s%s %s\n' "$(_c '1;31')" "err" "$(_c 0)" "$*" >&2; exit 1; }

# --- Config -----------------------------------------------------------------
# Split out from load_config so tests can exercise it without a real lab.conf.
require_lab_conf_vars() {
  : "${LAB_PREFIX:?LAB_PREFIX missing in lab.conf}"
  : "${LAB_USER:?LAB_USER missing in lab.conf}"
  : "${LAB_SSH_KEY:?LAB_SSH_KEY missing in lab.conf}"
  : "${VM_NAME:?VM_NAME missing in lab.conf}"
  : "${VM_CPU:?VM_CPU missing in lab.conf}"
  : "${VM_RAM:?VM_RAM missing in lab.conf}"
  : "${VM_DISK_GB:?VM_DISK_GB missing in lab.conf}"
}

load_config() {
  local cfg="${REPO_ROOT}/lab.conf"
  [[ -f "$cfg" ]] || die "lab.conf not found. Run: cp lab.conf.example lab.conf"
  # shellcheck disable=SC1090
  source "$cfg"
  require_lab_conf_vars
  # Expand ~ in the key path.
  LAB_SSH_KEY="${LAB_SSH_KEY/#\~/$HOME}"
  LAB_SSH_KEY="${LAB_SSH_KEY/#\$\{HOME\}/$HOME}"
}

# Full UTM VM name for a short name (e.g. kali -> redteam-kali).
vm_name() { echo "${LAB_PREFIX}-$1"; }

# Private key path derived from the public key in lab.conf.
priv_key() { echo "${LAB_SSH_KEY%.pub}"; }

# The box always runs Kali.
base_image() { echo "${IMAGES_DIR}/${KALI_IMG_FILE}"; }

# The NIC is UTM's "emulated" (QEMU SLIRP) mode with a host SSH port-forward.
# HOST_SSH_PORT is kept clear of the sibling repos' ranges (2200+index for
# redteam-lab, 2300+index for anon-egress) so all three labs can run at once.
VM_MAC="52:54:00:AA:00:01"
HOST_SSH_PORT=2400

# The only UTM display that shows a picture here (not a lab.conf knob). Both GL
# devices come up black on UTM 4.7.5, so Xorg renders on the CPU; the attacker
# role's desktop tuning is there to make that survivable.
VM_DISPLAY="virtio-gpu-pci"

# "dynamic" follows the UTM window; a WxH pins the guest and lets UTM scale. On a
# CPU-rendered display that is a free resize vs a frozen desktop, so a typo fails.
display_dynamic() {
  case "${DISPLAY_RESOLUTION:-1920x1080}" in
    dynamic) echo true ;;
    *) echo false ;;
  esac
}

# Every mode in DISPLAY_RESOLUTION, comma separated, or "" when following the
# window. Empty is a valid answer, so callers test the string and not the exit
# status. Comma and not space because up.sh hands this to Ansible as an
# -e "key=value" extra-var, and Ansible splits that form on whitespace.
display_modes() {
  local r="${DISPLAY_RESOLUTION:-1920x1080}" m out=""
  [[ "$r" == "dynamic" ]] && { echo ""; return 0; }
  for m in $r; do
    [[ "$m" =~ ^[0-9]+x[0-9]+$ ]] \
      || die "DISPLAY_RESOLUTION must be 'dynamic' or a space-separated list of <width>x<height>, got '${r}'"
    out="${out:+${out},}${m}"
  done
  echo "$out"
}

# The mode Xorg prefers at boot: the first in the list, or "" for dynamic. The
# failure is propagated by hand because 'local modes=$(...)' would mask the exit
# status, and a caller testing this function suspends set -e inside the subshell.
display_resolution() {
  local modes
  modes="$(display_modes)" || return 1
  echo "${modes%%,*}"
}

# XFCE compositing, as a bool for Ansible. Every effect is a full-screen redraw
# on the CPU here.
desktop_compositing() {
  case "${DESKTOP_COMPOSITING:-no}" in
    yes|true|1) echo true ;;
    no|false|0) echo false ;;
    *) die "DESKTOP_COMPOSITING must be 'yes' or 'no', got '${DESKTOP_COMPOSITING}'" ;;
  esac
}

# One knob for the Mullvad VPN app and Mullvad Browser, as a bool for Ansible.
# 'no' is a real removal, not a skip; see the attacker role's mullvad.yaml.
mullvad_enabled() {
  case "${MULLVAD:-no}" in
    yes|true|1) echo true ;;
    no|false|0) echo false ;;
    *) die "MULLVAD must be 'yes' or 'no', got '${MULLVAD}'" ;;
  esac
}

# Guest audio, as a bool for Ansible. Only the guest half is scriptable: UTM's
# AppleScript API has no sound property (see create-vm.applescript), so the
# sound device itself is added once by hand in UTM's VM settings, the way the
# shared folder is. 'no' removes the guest stack again.
audio_enabled() {
  case "${AUDIO:-no}" in
    yes|true|1) echo true ;;
    no|false|0) echo false ;;
    *) die "AUDIO must be 'yes' or 'no', got '${AUDIO}'" ;;
  esac
}

# Persistent data disk, kept outside the disposable OS lifecycle.
data_disk_path() { echo "${PERSIST_DIR}/data.qcow2"; }

# Host folder shared into the guest under the same name. One knob sets both
# sides, so it cannot end up called one thing on the Mac and another in the VM.
shared_dir() { echo "${SHARED_DIR:-${HOME}/Sandbox}"; }
shared_name() { basename "$(shared_dir)"; }

# Whether the box gets a persistent disk carrying /home. All or nothing: 'no'
# means no second disk is attached at all, not a disk with a smaller job.
keep_home() {
  case "${KEEP_HOME:-yes}" in
    yes|true|1) echo true ;;
    no|false|0) echo false ;;
    *) die "KEEP_HOME must be yes or no (got: ${KEEP_HOME})" ;;
  esac
}

# --- UTM bundles ------------------------------------------------------------
# UTM copies every disk into the VM's own bundle at creation, so the live data
# disk is that copy and not persist/data.qcow2. AppleScript cannot hand the path
# back: an imported drive exposes only an id, and asking for its "source" errors
# with -1728. So the bundle is located on disk and its config.plist read instead.
utm_documents_dir() {
  echo "${UTM_DOCUMENTS_DIR:-${HOME}/Library/Containers/com.utmapp.UTM/Data/Documents}"
}

# The UUID UTM knows a VM by, which is also the UUID in its config.plist. Prints
# nothing when the VM does not exist.
vm_uuid() {
  osascript "${REPO_ROOT}/scripts/vm-config.applescript" uuid "${1:?vm name required}" 2>/dev/null || true
}

# Bundle directory for a VM UUID. Matched on the UUID and not on the folder
# name, because UTM appends a suffix ("main-kali 2.utm") when a name comes back;
# a name match would then copy some other VM's disk back over persist/. Prints
# nothing when nothing matches.
vm_bundle_dir() {
  local uuid="${1:-}" plist
  [[ -n "$uuid" ]] || return 0
  for plist in "$(utm_documents_dir)"/*.utm/config.plist; do
    [[ -f "$plist" ]] || continue
    if [[ "$(plutil -extract Information.UUID raw -o - "$plist" 2>/dev/null || true)" == "$uuid" ]]; then
      dirname "$plist"
      return 0
    fi
  done
}

# The persistent data disk inside a bundle: the third drive, in the order
# create-vm.applescript adds them (boot, seed, data). Prints nothing when the
# bundle has no third drive or its image file is gone, so callers must treat an
# empty result as "not found" rather than as an empty path.
bundle_data_disk() {
  local bundle="${1:-}" image
  [[ -f "${bundle}/config.plist" ]] || return 0
  image="$(plutil -extract Drive.2.ImageName raw -o - "${bundle}/config.plist" 2>/dev/null || true)"
  [[ -n "$image" && -f "${bundle}/Data/${image}" ]] || return 0
  echo "${bundle}/Data/${image}"
}

# --- Platform guard ---------------------------------------------------------
require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This lab provisions UTM VMs and must run on macOS."
}

# Locate a qemu-img binary: prefer Homebrew, fall back to the one bundled in UTM.
find_qemu_img() {
  if command -v qemu-img >/dev/null 2>&1; then
    command -v qemu-img; return 0
  fi
  local bundled
  bundled="$(ls /Applications/UTM.app/Contents/Frameworks/qemu-*/bin/qemu-img 2>/dev/null | head -1 || true)"
  [[ -n "$bundled" ]] && { echo "$bundled"; return 0; }
  return 1
}

# Virtual size of a disk image in bytes. Prints nothing when the size cannot be
# read, so callers must handle an empty result.
disk_bytes() {
  local img="${1:?image path required}" qi
  qi="$(find_qemu_img)" || return 0
  # The trailing || true keeps a failing qemu-img from becoming the pipeline's
  # status under pipefail and killing the caller under set -e.
  "$qi" info "$img" 2>/dev/null | sed -n 's/.*(\([0-9][0-9]*\) bytes).*/\1/p' | head -1 || true
}

# --- utmctl -----------------------------------------------------------------
# utmctl ships inside UTM.app and is usually not on PATH, so resolve it once.
if command -v utmctl >/dev/null 2>&1; then
  UTMCTL="$(command -v utmctl)"
else
  UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"
fi

# True if UTM already has a VM with this exact name.
vm_exists() {
  "$UTMCTL" list 2>/dev/null | grep -q " ${1}\$"
}

# Stop a VM and wait for "stopped", not just "not started": utmctl stop passes
# through "stopping" first, so reconfiguring right after would race a mid-shutdown
# UTM. Empty status = already gone (success). Returns 1 on timeout.
# Usage: stop_vm_and_wait <name> [timeout_seconds, default 60]
stop_vm_and_wait() {
  local name="${1:?vm name required}" timeout="${2:-60}" waited=0 status
  "$UTMCTL" stop "$name" >/dev/null 2>&1 \
    || osascript -e "tell application \"UTM\" to stop virtual machine named \"${name}\"" >/dev/null 2>&1 \
    || true
  while [[ "$waited" -lt "$timeout" ]]; do
    status="$("$UTMCTL" status "$name" 2>/dev/null || true)"
    if [[ -z "$status" || "$status" == "stopped" ]]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# UTM's status for a VM ("started", "stopped", "paused", ...), or empty if the
# VM does not exist.
vm_status() {
  "$UTMCTL" status "${1:?vm name required}" 2>/dev/null || true
}

# Start a VM through utmctl, falling back to AppleScript on the odd UTM build
# where utmctl is unhappy.
start_vm() {
  local name="${1:?vm name required}"
  "$UTMCTL" start "$name" >/dev/null 2>&1 \
    || osascript -e "tell application \"UTM\" to start virtual machine named \"${name}\"" >/dev/null 2>&1
}
