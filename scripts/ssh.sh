#!/usr/bin/env bash
# SSH into the box. Usage: ssh.sh [name]  (name defaults to UTM_VM_NAME)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

short="${1:-$UTM_VM_NAME}"
[[ "$short" == "$UTM_VM_NAME" ]] || die "Unknown VM '${short}'. This box is '${UTM_VM_NAME}'."

key="$(priv_key)"
port="$HOST_SSH_PORT"
host="127.0.0.1"

log "Connecting to ${UTM_VM_NAME} (${host}:${port})"
exec ssh -i "$key" -p "$port" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${LAB_USER}@${host}"
