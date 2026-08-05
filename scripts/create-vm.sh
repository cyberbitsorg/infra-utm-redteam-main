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

# Bring an existing VM in line with lab.conf: cpu/ram through UTM. A disk= change
# cannot be applied to a VM that already exists (see the comment below), so it is
# only ever compared and reported, never acted on. Only stops and starts the VM
# when cpu/ram really differ, so a repeat 'make up' restarts nothing.
reconcile_existing_vm() {
  local want_cpu="$1" want_ram="$2" want_disk_gb="$3"
  local cur cur_cpu cur_ram disk candidate cur_bytes want_bytes cur_gb
  local change_hw=0

  cur="$(osascript "${REPO_ROOT}/scripts/vm-config.applescript" get "$name" 2>/dev/null || true)"
  read -r cur_cpu cur_ram <<<"$cur"
  if [[ -z "${cur_cpu:-}" || -z "${cur_ram:-}" ]]; then
    warn "${name}: could not read its UTM configuration, leaving it untouched"
    return 0
  fi
  if [[ "$cur_cpu" != "$want_cpu" || "$cur_ram" != "$want_ram" ]]; then
    change_hw=1
  fi

  # Disk size is compare-and-report ONLY, never acted on. UTM imports and
  # converts this staging file into its own bundle at VM creation time (see
  # the note by "cp -c" below); once a VM exists in UTM, this file is not its
  # live disk and resizing it here would change nothing the VM uses while
  # making the staging file lie about the VM's real size on every later run.
  # So the disk never contributes to the restart decision, and the file is
  # never written here.
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

  # No hardware change: nothing to reconfigure, but 'make up' must still bring a
  # stopped VM up (after a reboot or 'make down' the config is unchanged yet the
  # VM is not running). Without this, up.sh would wait on SSH for a VM nothing
  # ever started and time out. Starting an already-running VM is a no-op.
  if [[ "$change_hw" -eq 0 ]]; then
    if [[ "$(vm_status "$name")" == "started" ]]; then
      ok "${name} unchanged (${cur_cpu} cpu, ${cur_ram} MiB)"
    else
      log "${name}: unchanged but not running, starting it"
      start_vm "$name"
      ok "${name} started (${cur_cpu} cpu, ${cur_ram} MiB)"
    fi
    return 0
  fi

  log "${name}: ${cur_cpu}->${want_cpu} cpu, ${cur_ram}->${want_ram} MiB, restarting"

  if ! stop_vm_and_wait "$name"; then
    warn "${name}: did not stop within 60s, leaving it untouched"
    return 0
  fi
  osascript "${REPO_ROOT}/scripts/vm-config.applescript" set "$name" "$want_cpu" "$want_ram" >/dev/null
  start_vm "$name"
  ok "${name} updated: cpu and/or ram applied."
}

# An existing VM is reconciled, not recreated.
if vm_exists "$name"; then
  reconcile_existing_vm "$cpu" "$ram" "$disk_gb"
  echo "${name} ${ssh_port} ${mode}"
  exit 0
fi

log "Preparing disk for ${name}"
mkdir -p "$GEN_DIR"
base_img="$(base_image)"
[[ -f "$base_img" ]] || die "Base image missing (${base_img}). Run scripts/fetch-images.sh first."
QEMU_IMG="$(find_qemu_img)" || die "qemu-img not found"

# Name the working disk by its actual format so UTM/QEMU never guess wrong
# (Kali ships raw-in-.raw).
img_fmt="$("$QEMU_IMG" info "$base_img" | sed -n 's/^file format: //p' | head -1)"
case "$img_fmt" in
  qcow2) vm_disk="${GEN_DIR}/${name}.qcow2" ;;
  raw)   vm_disk="${GEN_DIR}/${name}.raw" ;;
  *)     vm_disk="${GEN_DIR}/${name}.${base_img##*.}" ;;
esac
# APFS clone (instant, space-free, sparse-preserving) with a plain-copy fallback.
# This file is staging input only. create-vm.applescript hands it to UTM once,
# and UTM imports and converts it into its own VM bundle under its app
# container, in a format of its choosing. From that point on, this staged
# file here in generated/ is never read or written by the running VM, so it
# must only be resized here, before creation, never afterward.
cp -c "$base_img" "$vm_disk" 2>/dev/null || cp "$base_img" "$vm_disk"

# Grow to the requested size, but never shrink (the Kali image already exceeds
# the usual default). This runs BEFORE the VM is created below, so the size
# really does land in the VM UTM is about to build.
cur_bytes="$(disk_bytes "$vm_disk")"
target_bytes=$(( disk_gb * 1024 * 1024 * 1024 ))
if [[ -n "$cur_bytes" && "$target_bytes" -gt "$cur_bytes" ]]; then
  # Pass the format explicitly. resize opens the image read-write, and for a
  # raw disk qemu-img would otherwise probe the format and print a warning
  # ("Image format was not specified ... probing guessed raw") on every run.
  # img_fmt came straight from `qemu-img info` above, so it is always set.
  "$QEMU_IMG" resize -f "$img_fmt" "$vm_disk" "${disk_gb}G" >/dev/null
fi

# Persistent data disk: created once, kept in persist/ across make destroy, and
# re-imported by UTM on every (re)creation. Never resized down; grown only by
# recreating. DATA_DISK_GB defaults to 40.
data_disk="$(data_disk_path)"
if [[ ! -f "$data_disk" ]]; then
  mkdir -p "$PERSIST_DIR"
  log "Creating persistent data disk ${data_disk} (${DATA_DISK_GB:-40}G)"
  "$QEMU_IMG" create -f qcow2 "$data_disk" "${DATA_DISK_GB:-40}G" >/dev/null
fi

log "Building cloud-init seed for ${name}"
seed="$("$(dirname "${BASH_SOURCE[0]}")/make-seed.sh" "$VM_NAME" "$mac" | tail -1)"

share="$(share_dir)"
mkdir -p "$share"
if [[ "$mode" == "nat" ]]; then
  log "Creating VM ${name} in UTM (nat NIC, ssh->127.0.0.1:${ssh_port}; mem ${ram}MiB, ${cpu} cpu, disk ${disk_gb}G, data ${DATA_DISK_GB:-40}G)"
else
  log "Creating VM ${name} in UTM (bridged NIC, own LAN IP; mem ${ram}MiB, ${cpu} cpu, disk ${disk_gb}G, data ${DATA_DISK_GB:-40}G)"
fi
vm_id="$(osascript "$(dirname "${BASH_SOURCE[0]}")/create-vm.applescript" \
  "$name" "$vm_disk" "$seed" "$ram" "$cpu" "$mac" "$ssh_port" "$mode" "$data_disk" "$share")"
ok "Created ${name} (${vm_id})"

log "Starting ${name}"
start_vm "$name"

# Emit a line the orchestrator parses: <name> <ssh_port> <net_mode>
echo "${name} ${ssh_port} ${mode}"
