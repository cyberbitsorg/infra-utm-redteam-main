#!/usr/bin/env bash
# SSH into a lab VM by short name. Usage: ssh.sh <short-name>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

short="${1:?Usage: make ssh <short-name> (e.g. attacker)}"

# Find the VM index to compute its host SSH port.
idx=0; found=0; known=""
for entry in "${LAB_VMS[@]}"; do
  idx=$((idx + 1))
  parse_vm_entry "$entry"
  known+="${VM_SHORT} "
  [[ "$VM_SHORT" == "$short" ]] && { found=1; break; }
done
[[ "$found" == "1" ]] || die "Unknown VM '${short}'. Known: ${known}"

mode="$(nic_mode)"
key="$(priv_key)"
name="$(vm_name "$short")"

if [[ "$mode" == "nat" ]]; then
  port="$(ssh_port_for "$idx")"
  host="127.0.0.1"
else
  port=22
  host="$(awk -v h="$short:" '
    $1==h {found=1}
    found && $1=="ansible_host:" {print $2; exit}' "$INVENTORY_FILE" 2>/dev/null || true)"
  [[ -z "$host" ]] && host="$("$UTMCTL" ip-address "$name" 2>/dev/null \
    | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.' | head -1 || true)"
  [[ -n "$host" ]] || die "Could not find ${short}'s LAN IP. Run 'make up' or check the VM is running."
fi

log "Connecting to ${short} (${host}:${port})"
exec ssh -i "$key" -p "$port" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${LAB_USER}@${host}"
