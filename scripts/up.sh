#!/usr/bin/env bash
# Orchestrator: preflight -> fetch image -> create VM -> discover/wait SSH ->
# generate inventory -> Ansible. Fully hands-off.
# Flags: --provision-only (no Ansible), --configure-only (Ansible only)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS="$(dirname "${BASH_SOURCE[0]}")"

require_macos
load_config

MODE="all"
case "${1:-}" in
  --provision-only) MODE="provision" ;;
  --configure-only) MODE="configure" ;;
  "") MODE="all" ;;
  *) die "Unknown flag: $1" ;;
esac

run_ansible() {
  log "Installing Ansible Galaxy requirements"
  ansible-galaxy collection install -r "${ANSIBLE_DIR}/requirements.yaml" >/dev/null
  log "Running Ansible playbook"
  # The console password goes through a 0600 file rather than -e, so it never
  # shows up in the host process list. The non-secret vars stay plain -e.
  local vars_file pw esc
  vars_file="$(mktemp)"
  chmod 600 "$vars_file"
  trap "rm -f '${vars_file}'" EXIT
  pw="${ATTACKER_PASSWORD:-redteam}"
  # Double every ' the way a single-quoted YAML scalar escapes one, so any
  # character in the password stays literal. Unquoted so \' is a literal quote.
  esc=${pw//\'/\'\'}
  printf "attacker_password: '%s'\n" "$esc" > "$vars_file"
  ( cd "$REPO_ROOT" && ansible-playbook "${ANSIBLE_DIR}/playbook.yaml" \
      -e "attacker_toolset=${KALI_TOOLSET:-default}" \
      -e "attacker_gui=${ATTACKER_GUI:-xfce}" \
      -e "attacker_clipboard=${CLIPBOARD:-yes}" \
      -e "attacker_audio=$(audio_enabled)" \
      -e "attacker_display_resolution=$(display_resolution)" \
      -e "attacker_compositing=$(desktop_compositing)" \
      -e "attacker_keep_home=$(keep_home)" \
      -e "attacker_mullvad=$(mullvad_enabled)" \
      -e "attacker_shared_name=$(shared_name)" \
      -e "@${vars_file}" )
  ok "Configuration complete"
}

if [[ "$MODE" == "configure" ]]; then
  [[ -f "$INVENTORY_FILE" ]] || die "No inventory. Run a full 'make up' first."
  run_ansible
  exit 0
fi

"${SCRIPTS}/preflight.sh"
"${SCRIPTS}/fetch-images.sh"

log "Provisioning the VM"
result="$("${SCRIPTS}/create-vm.sh" | tail -1)"
read -r name port <<<"$result"
host="127.0.0.1"

log "Waiting for the VM to accept SSH"
"${SCRIPTS}/wait-ssh.sh" "$host" "$port" 420

printf '%s %s %s %s\n' "$VM_NAME" "$name" "$host" "$port" | "${SCRIPTS}/gen-inventory.sh"

if [[ "$MODE" == "provision" ]]; then
  ok "Provisioning done. Run 'make configure' to apply Ansible."
  exit 0
fi

run_ansible
echo
ok "Box is up. Try: make ssh kali"
