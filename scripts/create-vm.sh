#!/usr/bin/env bash
# Create, seed and start the Kali box, or bring an existing VM in line with the
# cpu/ram in lab.conf. Reads its configuration from lab.conf; takes no arguments.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_config

name="$(vm_name "$VM_NAME")"
mac="$VM_MAC"
cpu="$VM_CPU"
ram="$VM_RAM"
disk_gb="$VM_DISK_GB"
mode="$(nic_mode)"
if [[ "$mode" == "nat" ]]; then
  ssh_port="$HOST_SSH_PORT"
else
  ssh_port=0
fi

# Bring an existing VM in line with lab.conf's cpu/ram/display. Only stops and
# starts it when something really differs, so a repeat 'make up' restarts
# nothing. NET_MODE is not reconciled: UTM cannot rewire a NIC on an existing
# VM, and up.sh catches the mismatch when it discovers the address.
reconcile_existing_vm() {
  local want_cpu="$1" want_ram="$2" want_disk_gb="$3" want_display="$4" want_dynres="$5"
  local cur cur_cpu cur_ram cur_display cur_dynres disk candidate cur_bytes want_bytes cur_gb
  local change_hw=0

  cur="$(osascript "${REPO_ROOT}/scripts/vm-config.applescript" get "$name" 2>/dev/null || true)"
  read -r cur_cpu cur_ram cur_display cur_dynres <<<"$cur"
  if [[ -z "${cur_cpu:-}" || -z "${cur_ram:-}" || -z "${cur_display:-}" || -z "${cur_dynres:-}" ]]; then
    warn "${name}: could not read its UTM configuration, leaving it untouched"
    return 0
  fi
  if [[ "$cur_cpu" != "$want_cpu" || "$cur_ram" != "$want_ram" \
     || "$cur_display" != "$want_display" || "$cur_dynres" != "$want_dynres" ]]; then
    change_hw=1
  fi

  # Compare-and-report only. UTM copied this staging file into its own bundle
  # at creation time, so it is no longer the VM's live disk: resizing it here
  # would change nothing and only make the staging file lie about the real size.
  disk=""
  for candidate in "${GEN_DIR}/${name}.qcow2" "${GEN_DIR}/${name}.raw"; do
    if [[ -f "$candidate" ]]; then
      disk="$candidate"
      break
    fi
  done
  if [[ -n "$disk" ]]; then
    cur_bytes="$(disk_bytes "$disk")"
    want_bytes=$(( want_disk_gb * 1024 * 1024 * 1024 ))
    if [[ -n "$cur_bytes" ]]; then
      cur_gb=$(( cur_bytes / 1024 / 1024 / 1024 ))
      if [[ "$want_bytes" -gt "$cur_bytes" ]]; then
        warn "${name}: VM_DISK_GB=${want_disk_gb} is larger than the ${cur_gb}G it was created with. A disk cannot be grown on a VM that already exists in UTM; run 'make destroy' then 'make up' to rebuild it at the new size."
      elif [[ "$want_bytes" -lt "$cur_bytes" ]]; then
        warn "${name}: VM_DISK_GB=${want_disk_gb} is below the current ${cur_gb}G. Disks are never shrunk, leaving it as is."
      fi
    else
      warn "${name}: could not check its disk size (qemu-img could not read ${disk})"
    fi
  else
    warn "${name}: could not check its disk size (no staging file in ${GEN_DIR}, was generated/ cleared after this VM was created?)"
  fi

  # Nothing to reconfigure, but 'make up' must still start a stopped VM (after
  # a reboot or 'make down' the config is unchanged yet nothing is running),
  # or up.sh would wait out its SSH timeout. Starting a running VM is a no-op.
  if [[ "$change_hw" -eq 0 ]]; then
    if [[ "$(vm_status "$name")" == "started" ]]; then
      ok "${name} unchanged (${cur_cpu} cpu, ${cur_ram} MiB, ${cur_display}, dynres ${cur_dynres})"
    else
      log "${name}: unchanged but not running, starting it"
      start_vm "$name"
      ok "${name} started (${cur_cpu} cpu, ${cur_ram} MiB, ${cur_display}, dynres ${cur_dynres})"
    fi
    return 0
  fi

  log "${name}: ${cur_cpu}->${want_cpu} cpu, ${cur_ram}->${want_ram} MiB, ${cur_display}->${want_display}, dynres ${cur_dynres}->${want_dynres}, restarting"

  if ! stop_vm_and_wait "$name"; then
    warn "${name}: did not stop within 60s, leaving it untouched"
    return 0
  fi
  osascript "${REPO_ROOT}/scripts/vm-config.applescript" set \
    "$name" "$want_cpu" "$want_ram" "$want_display" "$want_dynres" >/dev/null
  start_vm "$name"
  ok "${name} updated: cpu, ram, display and/or dynamic resolution applied."
}

# An existing VM is reconciled, not recreated.
if vm_exists "$name"; then
  reconcile_existing_vm "$cpu" "$ram" "$disk_gb" "$VM_DISPLAY" "$(display_dynamic)"
  echo "${name} ${ssh_port} ${mode}"
  exit 0
fi

log "Preparing disk for ${name}"
mkdir -p "$GEN_DIR"
base_img="$(base_image)"
[[ -f "$base_img" ]] || die "Base image missing (${base_img}). Run scripts/fetch-images.sh first."
QEMU_IMG="$(find_qemu_img)" || die "qemu-img not found"

# Name the working disk by its actual format so UTM/QEMU never guess wrong.
img_fmt="$("$QEMU_IMG" info "$base_img" | sed -n 's/^file format: //p' | head -1)"
case "$img_fmt" in
  qcow2) vm_disk="${GEN_DIR}/${name}.qcow2" ;;
  raw)   vm_disk="${GEN_DIR}/${name}.raw" ;;
  *)     vm_disk="${GEN_DIR}/${name}.${base_img##*.}" ;;
esac
# APFS clone (instant, sparse-preserving) with a plain-copy fallback. Staging
# input only: UTM copies it into its own bundle at creation, so it must be
# resized here, before the VM exists, and never afterwards.
cp -c "$base_img" "$vm_disk" 2>/dev/null || cp "$base_img" "$vm_disk"

# Grow to the requested size, never shrink. -f suppresses the format-probing
# warning qemu-img prints for a raw disk on every run.
cur_bytes="$(disk_bytes "$vm_disk")"
target_bytes=$(( disk_gb * 1024 * 1024 * 1024 ))
if [[ -n "$cur_bytes" && "$target_bytes" -gt "$cur_bytes" ]]; then
  "$QEMU_IMG" resize -f "$img_fmt" "$vm_disk" "${disk_gb}G" >/dev/null
fi

# Persistent data disk: created once, kept in persist/ across make destroy, and
# re-imported by UTM on every (re)creation. Grown only by recreating.
data_disk="$(data_disk_path)"
if [[ ! -f "$data_disk" ]]; then
  mkdir -p "$PERSIST_DIR"
  log "Creating persistent data disk ${data_disk} (${DATA_DISK_GB:-40}G)"
  "$QEMU_IMG" create -f qcow2 "$data_disk" "${DATA_DISK_GB:-40}G" >/dev/null
fi

log "Building cloud-init seed for ${name}"
seed="$("$(dirname "${BASH_SOURCE[0]}")/make-seed.sh" "$VM_NAME" "$mac" | tail -1)"

shared="$(shared_dir)"
mkdir -p "$shared"
if [[ "$mode" == "nat" ]]; then
  log "Creating VM ${name} in UTM (nat NIC, ssh->127.0.0.1:${ssh_port}; mem ${ram}MiB, ${cpu} cpu, disk ${disk_gb}G, data ${DATA_DISK_GB:-40}G)"
else
  log "Creating VM ${name} in UTM (bridged NIC, own LAN IP; mem ${ram}MiB, ${cpu} cpu, disk ${disk_gb}G, data ${DATA_DISK_GB:-40}G)"
fi
vm_id="$(osascript "$(dirname "${BASH_SOURCE[0]}")/create-vm.applescript" \
  "$name" "$vm_disk" "$seed" "$ram" "$cpu" "$mac" "$ssh_port" "$mode" "$data_disk" "$shared" "$VM_DISPLAY" "$(display_dynamic)")"
ok "Created ${name} (${vm_id})"

log "Starting ${name}"
start_vm "$name"

# Emit a line the orchestrator parses: <name> <ssh_port> <net_mode>
echo "${name} ${ssh_port} ${mode}"
