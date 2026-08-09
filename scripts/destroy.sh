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

# UTM imported persist/data.qcow2 into the VM bundle at creation, so the live
# data is the bundle copy. Copy it back out while the VM is stopped and the
# qcow2 is quiescent, so the next make up re-imports current work. This copy IS
# the box's /home, so a failure stops the destroy instead of warning: a warning
# scrolls past and the delete below is not undoable.
if [[ "$(keep_home)" != "true" ]]; then
  log "KEEP_HOME=no: this box has no persistent disk, so there is nothing to keep"
elif [[ "${PRESERVE_DATA:-yes}" != "yes" ]]; then
  warn "PRESERVE_DATA=${PRESERVE_DATA}: throwing the persistent /home away with the VM"
elif vm_exists "$name"; then
  bundle_disk="$(bundle_data_disk "$(vm_bundle_dir "$(vm_uuid "$name")")")"
  [[ -n "$bundle_disk" ]] || die "${name}: could not find its data disk in the UTM bundle under $(utm_documents_dir), so /home would be deleted with the VM. The VM is stopped but still there. Re-run with PRESERVE_DATA=no to destroy it anyway."
  log "Preserving data disk from ${name} -> $(data_disk_path)"
  mkdir -p "$PERSIST_DIR"
  cp "$bundle_disk" "$(data_disk_path).new" \
    && mv -f "$(data_disk_path).new" "$(data_disk_path)" \
    || die "${name}: copying ${bundle_disk} to $(data_disk_path) failed. The VM is stopped but still there, so nothing is lost."
  # The size is the tell: a disk that never held work is a couple of hundred KB.
  ok "Data disk preserved ($(du -h "$(data_disk_path)" | cut -f1))"
fi

log "Deleting ${name}"
"$UTMCTL" delete "$name" 2>/dev/null \
  || osascript -e "tell application \"UTM\" to delete virtual machine named \"${name}\"" 2>/dev/null \
  || warn "Could not delete ${name} (already gone?)"

log "Removing generated artifacts"
rm -rf "$GEN_DIR"
rm -f "$INVENTORY_FILE"
ok "Box destroyed. Base image kept in images/, work kept in persist/."
