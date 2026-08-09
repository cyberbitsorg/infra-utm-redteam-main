#!/usr/bin/env bash
# Attach to the VM's serial console (ttyAMA0, exposed by UTM as a pseudo-tty).
# Works on any kernel, which makes it the recovery path when the display or the
# network is what is broken. The pty path changes on every start, so it is
# queried live. Logging in needs ATTACKER_PASSWORD from lab.conf.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

short="${1:-$VM_NAME}"

# Validated here so a typo fails clearly instead of inside AppleScript.
[[ "$short" == "$VM_NAME" ]] || die "Unknown VM '${short}'. This box is '${VM_NAME}'."

name="$(vm_name "$VM_NAME")"
[[ "$(vm_status "$name")" == "started" ]] \
  || die "${name} is not running (status: $(vm_status "$name" || echo 'not created')). Run 'make up' first."

# Ask UTM for the first serial port's host pty.
read -r iface dev <<<"$(osascript -e "tell application \"UTM\"
  set vm to virtual machine named \"${name}\"
  set sps to serial ports of vm
  if (count of sps) is 0 then return \"none -\"
  set sp to item 1 of sps
  return (interface of sp as text) & \" \" & (address of sp as text)
end tell" 2>/dev/null)"

case "${iface:-}" in
  ptty) ;;
  none) die "${name} has no serial port in UTM. Add one in UTM (Edit -> new device -> Serial) or rebuild the VM." ;;
  unavailable) die "${name}'s serial port is held by the UTM GUI. Open the VM's serial/terminal view in the UTM window instead." ;;
  "") die "Could not read ${name}'s serial port from UTM. Is UTM running and is automation permitted?" ;;
  *) die "${name}'s serial port uses the '${iface}' interface, which this script does not handle (expected ptty)." ;;
esac
[[ -e "$dev" ]] || die "UTM reports ${name}'s console at ${dev}, but that device does not exist."

log "Console for ${name} at ${dev}"
log "Press Enter for a login prompt. Detach with: Ctrl-a then k (then y)"
# screen is the only terminal emulator guaranteed present on macOS. Exec it so
# Ctrl-C and resizes go to the console, not to this script.
exec screen "$dev" 115200
