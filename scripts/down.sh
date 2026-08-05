#!/usr/bin/env bash
# Stop the VM (it remains in UTM for a later 'make up').
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

name="$(vm_name "$VM_NAME")"
log "Stopping ${name}"
"$UTMCTL" stop "$name" 2>/dev/null \
  || osascript -e "tell application \"UTM\" to stop virtual machine named \"${name}\"" 2>/dev/null \
  || warn "Could not stop ${name} (not running?)"
ok "VM stopped"
