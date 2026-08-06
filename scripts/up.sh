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
  # The console password goes through a 0600 file, not -e on the command line,
  # so it never appears in the host process list (ps auxww). Single-quoted YAML
  # scalar with '' escaping keeps any character in the password literal. The
  # non-secret toolset/gui stay as plain -e. Bake the path into the trap so it
  # is cleaned up even if ansible-playbook fails under set -e.
  local vars_file pw esc
  vars_file="$(mktemp)"
  chmod 600 "$vars_file"
  trap "rm -f '${vars_file}'" EXIT
  pw="${ATTACKER_PASSWORD:-redteam}"
  # Unquoted assignment so \' is a literal ' in the pattern/replacement: double
  # each ' to '' the way a single-quoted YAML scalar escapes a quote.
  esc=${pw//\'/\'\'}
  printf "attacker_password: '%s'\n" "$esc" > "$vars_file"
  ( cd "$REPO_ROOT" && ansible-playbook "${ANSIBLE_DIR}/playbook.yaml" \
      -e "attacker_toolset=${KALI_TOOLSET:-default}" \
      -e "attacker_gui=${ATTACKER_GUI:-xfce}" \
      -e "attacker_clipboard=${CLIPBOARD:-yes}" \
      -e "attacker_keep_home=$(keep_home)" \
      -e "attacker_sandbox_name=$(sandbox_name)" \
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

mode="$(nic_mode)"
log "Provisioning the VM in ${mode} mode"
result="$("${SCRIPTS}/create-vm.sh" | tail -1)"
read -r name port vmmode <<<"$result"

if [[ "$vmmode" == "bridged" ]]; then
  log "Discovering ${name} LAN IP (qemu-guest-agent)"
  host=""
  deadline=$(( $(date +%s) + 180 ))
  while :; do
    # First non-loopback IPv4 the guest agent reports.
    host="$("$UTMCTL" ip-address "$name" 2>/dev/null \
      | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | grep -v '^127\.' | head -1 || true)"
    [[ -n "$host" ]] && break
    [[ $(date +%s) -lt $deadline ]] || die "Timed out getting ${name} LAN IP. Is DHCP available on the bridged network?"
    sleep 5
  done
  port=22
  ok "${name} at ${host}:22"
else
  host="127.0.0.1"
fi

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
