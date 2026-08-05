#!/usr/bin/env bash
# Show the status of the VM.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

name="$(vm_name "$VM_NAME")"
status="$("$UTMCTL" status "$name" 2>/dev/null || echo "not created")"
printf '%-28s %-10s\n' "VM" "STATUS"
printf '%-28s %-10s\n' "----------------------------" "----------"
printf '%-28s %-10s\n' "$name" "$status"
