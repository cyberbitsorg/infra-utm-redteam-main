#!/usr/bin/env bash
# Render a cloud-init NoCloud seed ISO for the VM.
# Usage: make-seed.sh <name> <mac>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_config
short="${1:?name required}"
mac="${2:?nic mac required}"

mkdir -p "$GEN_DIR"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

template="${CLOUDINIT_DIR}/kali.user-data.yaml"
[[ -f "$template" ]] || die "Cloud-init template missing: ${template}"

pubkey="$(cat "$LAB_SSH_KEY")"
hostname="$(vm_name "$short")"

# user-data: substitute username, hostname and SSH public key.
sed \
  -e "s|@@LAB_USER@@|${LAB_USER}|g" \
  -e "s|@@HOSTNAME@@|${hostname}|g" \
  -e "s|@@SSH_KEY@@|${pubkey}|g" \
  "$template" > "${work}/user-data"

# meta-data: identity.
cat > "${work}/meta-data" <<EOF
instance-id: ${hostname}
local-hostname: ${hostname}
EOF

# network-config v2: single NIC on DHCP, matched by MAC so the interface name
# does not matter.
cat > "${work}/network-config" <<EOF
version: 2
ethernets:
  primary:
    match:
      macaddress: "${mac}"
    dhcp4: true
EOF

seed="${GEN_DIR}/${hostname}.seed.iso"
# hdiutil makehybrid refuses to overwrite, so clear a stale seed first.
rm -f "$seed"

# Volume label MUST be "cidata" for the NoCloud datasource to be picked up.
if command -v xorriso >/dev/null 2>&1; then
  xorriso -as genisoimage -quiet -output "$seed" -volid cidata -joliet -rock \
    "${work}/user-data" "${work}/meta-data" "${work}/network-config"
elif command -v mkisofs >/dev/null 2>&1; then
  mkisofs -quiet -output "$seed" -volid cidata -joliet -rock \
    "${work}/user-data" "${work}/meta-data" "${work}/network-config"
else
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata \
    -o "$seed" "$work"
fi

echo "$seed"
