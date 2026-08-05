#!/usr/bin/env bash
# Shared helpers, sourced by every script. Not meant to be run directly.

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
# All four write to stderr, so a script's stdout carries only its data. That
# matters because callers capture that data: up.sh does
# result="$(create-vm.sh ... | tail -1)" and create-vm.sh does
# seed="$(make-seed.sh ... | tail -1)". When log/ok wrote to stdout, every
# message from those scripts was swallowed by the command substitution and
# never reached the terminal, including the reconcile telling you it was about
# to restart a VM.
_c() { printf '\033[%sm' "$1"; }
log()  { printf '%s%s%s %s\n' "$(_c '1;34')" "==>" "$(_c 0)" "$*" >&2; }
ok()   { printf '%s%s%s %s\n' "$(_c '1;32')" " ok" "$(_c 0)" "$*" >&2; }
warn() { printf '%s%s%s %s\n' "$(_c '1;33')" " ! " "$(_c 0)" "$*" >&2; }
die()  { printf '%s%s%s %s\n' "$(_c '1;31')" "err" "$(_c 0)" "$*" >&2; exit 1; }

# --- Config -----------------------------------------------------------------
# Validate the lab.conf variables every script depends on. Split out from
# load_config so tests can exercise it directly against fake values, without
# needing a real lab.conf on disk.
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

# --- Networking mode --------------------------------------------------------
# NET_MODE decides the single NIC's mode. 'nat' (default) is the portable
# emulated/SLIRP NIC with a host SSH port-forward; 'bridged' puts the box on
# the physical LAN with its own DHCP address and NO host forward. This is the
# one knob; the security-free single-box design has nothing else to protect.
nic_mode() {
  local m="${NET_MODE:-nat}"
  case "$m" in
    nat|bridged) echo "$m" ;;
    *) die "NET_MODE must be 'nat' or 'bridged', got '${m}'" ;;
  esac
}

# The single VM's fixed provisioning identity (one box, so no per-index math).
# HOST_SSH_PORT is the NAT-mode host forward; bridged reaches port 22 on the
# guest's own LAN IP instead. Kept clear of the sibling repos' ranges, which
# hand out 2200+index (redteam-lab) and 2300+index (anon-egress), so all three
# labs can run at once.
VM_MAC="52:54:00:AA:00:01"
HOST_SSH_PORT=2400

# Persistent data disk kept OUTSIDE the disposable OS lifecycle.
data_disk_path() { echo "${PERSIST_DIR}/data.qcow2"; }

# Host-side shared folder mounted live into the guest.
share_dir() { echo "${REPO_ROOT}/share"; }

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

# Virtual size of a disk image in bytes, per qemu-img. Prints nothing if the
# size cannot be read, so callers must handle an empty result.
disk_bytes() {
  local img="${1:?image path required}" qi
  qi="$(find_qemu_img)" || return 0
  # qemu-img can fail (missing, unreadable or corrupt image) while sed and
  # head still succeed on empty input; under pipefail that failure becomes
  # the pipeline's status and would otherwise kill the caller under set -e.
  "$qi" info "$img" 2>/dev/null | sed -n 's/.*(\([0-9][0-9]*\) bytes).*/\1/p' | head -1 || true
}

# --- utmctl -----------------------------------------------------------------
# utmctl ships inside UTM.app and is usually NOT on PATH. Resolve it once so
# every script can call "$UTMCTL" and work whether or not you added it to PATH.
if command -v utmctl >/dev/null 2>&1; then
  UTMCTL="$(command -v utmctl)"
else
  UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"
fi

# True if UTM already has a VM with this exact name.
vm_exists() {
  "$UTMCTL" list 2>/dev/null | grep -q " ${1}\$"
}

# Stop a VM and wait for it to really be stopped. utmctl stop asks the guest to
# shut down, which is not instant, and passes through intermediate statuses
# (e.g. "stopping") before landing on "stopped". Waits for exactly "stopped",
# not merely "not started", so a caller that immediately reconfigures the VM
# never races a UTM that is still mid-shutdown. Returns early (success) if the
# status is empty, meaning the VM does not exist, so a caller like destroy.sh
# does not burn the full timeout on a VM that is already gone. Returns 1 if it
# is still not stopped after the timeout, so callers can decide whether that
# is fatal.
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
# where utmctl is unhappy. Both create-vm.sh paths (new VM, reconciled VM) route
# through here so the start command lives in exactly one place.
start_vm() {
  local name="${1:?vm name required}"
  "$UTMCTL" start "$name" >/dev/null 2>&1 \
    || osascript -e "tell application \"UTM\" to start virtual machine named \"${name}\"" >/dev/null 2>&1
}
