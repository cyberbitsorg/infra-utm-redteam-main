#!/usr/bin/env bash
# Verify the host can build the lab and generate an SSH key if needed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_macos
load_config

log "Checking Apple Silicon"
[[ "$(uname -m)" == "arm64" ]] || warn "Not arm64. ARM64 cloud images will not boot on Intel."

log "Checking UTM"
[[ -d /Applications/UTM.app ]] || die "UTM not found. Install from https://mac.getutm.app/"
command -v utmctl >/dev/null 2>&1 \
  || warn "utmctl not on PATH. It ships inside UTM.app; scripts fall back to that path."

log "Checking qemu-img (disk resize)"
if QEMU_IMG="$(find_qemu_img)"; then
  ok "qemu-img: ${QEMU_IMG}"
else
  die "qemu-img not found. Install with: brew install qemu"
fi

log "Checking ISO tooling (cloud-init seed)"
if command -v xorriso >/dev/null 2>&1 || command -v mkisofs >/dev/null 2>&1 \
   || command -v hdiutil >/dev/null 2>&1; then
  ok "ISO builder available"
else
  die "No ISO builder found. Install with: brew install xorriso"
fi

log "Checking Ansible"
command -v ansible-playbook >/dev/null 2>&1 \
  || die "Ansible not found. Install with: brew install ansible"

log "Checking NET_MODE"
mode="$(nic_mode)"           # dies on an invalid value
ok "Network mode: ${mode}"

# The share name becomes a mount point in the guest's fstab, where whitespace
# would need octal escaping and silently breaks the mount instead.
case "$(shared_name)" in
  *[[:space:]]*|"") die "SHARED_DIR must end in a folder name without spaces (got: $(shared_dir))" ;;
esac

keep_home >/dev/null   # dies on an invalid value

log "Ensuring persist/ and the share folder exist"
mkdir -p "$PERSIST_DIR" "$(shared_dir)"
ok "persist/ and $(shared_dir) present (mounts as ~/$(shared_name) in the guest)"

log "Checking SSH key: ${LAB_SSH_KEY}"
if [[ -f "$LAB_SSH_KEY" ]]; then
  ok "Public key present"
else
  priv="$(priv_key)"
  warn "Key missing, generating ${priv}"
  ssh-keygen -t ed25519 -N "" -C "redteam-main" -f "$priv"
  ok "Generated ${priv} and ${priv}.pub"
fi

ok "Preflight passed"
