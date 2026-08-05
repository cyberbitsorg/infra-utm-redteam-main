#!/usr/bin/env bash
# SSH into the box. Usage: ssh.sh [name]  (name defaults to VM_NAME)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

short="${1:-$VM_NAME}"
[[ "$short" == "$VM_NAME" ]] || die "Unknown VM '${short}'. This box is '${VM_NAME}'."

mode="$(nic_mode)"
key="$(priv_key)"
name="$(vm_name "$VM_NAME")"

if [[ "$mode" == "nat" ]]; then
  port="$HOST_SSH_PORT"
  host="127.0.0.1"
else
  port=22
  host="$(awk -v h="${VM_NAME}:" '
    $1==h {found=1}
    found && $1=="ansible_host:" {print $2; exit}' "$INVENTORY_FILE" 2>/dev/null || true)"
  [[ -z "$host" ]] && host="$("$UTMCTL" ip-address "$name" 2>/dev/null \
    | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.' | head -1 || true)"
  [[ -n "$host" ]] || die "Could not find ${VM_NAME}'s LAN IP. Run 'make up' or check the VM is running."
fi

log "Connecting to ${VM_NAME} (${host}:${port})"
exec ssh -i "$key" -p "$port" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${LAB_USER}@${host}"
