#!/usr/bin/env bash
# Stop and delete the VM and remove generated artifacts. Prompts once before
# deleting. Base image in images/ and persistent work in persist/ are kept.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

name="$(vm_name "$VM_NAME")"
echo "This will DELETE this UTM VM and all its data:"
echo "  - ${name}"
read -r -p "Type 'yes' to continue: " confirm
[[ "$confirm" == "yes" ]] || { warn "Aborted"; exit 1; }

log "Stopping ${name}"
stop_vm_and_wait "$name" 30 || warn "${name} did not stop in time, trying to delete anyway"

# Preserve the persistent data disk: UTM imported persist/data.qcow2 into the
# VM bundle at creation, so the LIVE data is the bundle copy, not persist/.
# Copy it back out (now that the VM is stopped, so the qcow2 is quiescent)
# before deleting the VM, so a rebuild re-imports current work. Best-effort:
# a failure here must not block teardown, but is warned.
if vm_exists "$name"; then
  bundle_disk="$(osascript "${REPO_ROOT}/scripts/vm-config.applescript" datadisk "$name" 2>/dev/null || true)"
  if [[ -n "$bundle_disk" && -f "$bundle_disk" ]]; then
    log "Preserving data disk from ${name} -> $(data_disk_path)"
    mkdir -p "$PERSIST_DIR" \
      && cp "$bundle_disk" "$(data_disk_path).new" \
      && mv -f "$(data_disk_path).new" "$(data_disk_path)" \
      && ok "Data disk preserved" \
      || warn "Could not preserve data disk from ${name}; persist/ left as-is"
  else
    warn "${name}: no data disk found in its bundle to preserve"
  fi
fi

log "Deleting ${name}"
"$UTMCTL" delete "$name" 2>/dev/null \
  || osascript -e "tell application \"UTM\" to delete virtual machine named \"${name}\"" 2>/dev/null \
  || warn "Could not delete ${name} (already gone?)"

log "Removing generated artifacts"
rm -rf "$GEN_DIR"
rm -f "$INVENTORY_FILE"
ok "Box destroyed. Base image kept in images/, work kept in persist/."
