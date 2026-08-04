# Main Kali Attack Box Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `infra-utm-redteam-main` — a one-command, reproducible, single-VM main Kali attack box on UTM (Apple Silicon), with selectable NAT/bridged networking, a full toolset, an always-on XFCE desktop, and clipboard + shared-folder + persistent-data-disk host integration.

**Architecture:** Three provisioning layers driven by `make` + `lab.conf`: UTM AppleScript provisioning (`scripts/` + `create-vm.applescript`), cloud-init first-boot bootstrap (`cloud-init/`), and Ansible configuration (`ansible/`, one `attacker` role). Heavily adapted from two sibling repos that remain on disk as the source of truth: `../infra-utm-redteam-lab` (base machinery + attacker role) and `../infra-utm-anon-egress` (selectable NIC layout, `console.sh`, SPICE touches). Strip the lab's targets/segment and all of anon-egress's anonymity stack; add persistence and net-mode selection.

**Tech Stack:** bash (macOS 3.2-compatible), AppleScript (UTM scripting dictionary), cloud-init NoCloud, Ansible (community.general), qemu-img, Kali Linux ARM64 genericcloud image.

**Spec:** `docs/superpowers/specs/2026-08-04-utm-redteam-main-design.md`

**Sibling source paths (read these while implementing):**
- LAB = `/Users/henk/Code/infra-utm-redteam-lab`
- ANON = `/Users/henk/Code/infra-utm-anon-egress`

## Global Constraints

- **Platform:** Apple Silicon (arm64) macOS only. Images are ARM64. Scripts must run on the bash 3.2 that ships with macOS — no associative arrays, no `${x^^}`.
- **UTM integration is centralized:** `scripts/create-vm.applescript` and `scripts/vm-config.applescript` are the ONLY files that use UTM AppleScript property keys. If a UTM version rejects a key, fix it there only.
- **Image pin:** `KALI_VERSION="2026.2"`, genericcloud arm64, from the per-release directory `https://kali.download/cloud-images/kali-${KALI_VERSION}/` (never `current/`). `KALI_IMG_FILE="kali-genericcloud-arm64.raw"`.
- **SSH is key-only** on the box (`ssh_pwauth: false`). `ATTACKER_PASSWORD` is the console/GUI password only.
- **No anonymity logic** anywhere (no gateway, WireGuard, nftables, Mullvad, unbound, verify). No vulnerable targets, no isolated lab segment.
- **Single VM** shipped; `LAB_VMS` stays an array so it can grow later.
- **Config defaults:** `NET_MODE=nat`, `KALI_TOOLSET=default`, `KALI_TOOL_GROUPS=""` (additive), `ATTACKER_GUI=xfce`, `CLIPBOARD=yes`, `PERSIST_MODE=data`, `DATA_DISK_GB=40`, `LAB_CPU=6`, `LAB_RAM=8192`, `LAB_DISK_GB=80`.
- **SSH port base:** `2200`; VM at index `i` uses host port `2200+i` in NAT mode.
- **License:** GPLv3 (copy LAB/LICENSE verbatim).
- **Commits:** single-line subject, no body, no Claude/Anthropic trailer (user's global rule). This plan shows `git commit -m "..."` accordingly.

---

### Task 1: Repo scaffold — license, gitignore, ansible config, directory skeleton

**Files:**
- Create: `LICENSE` (copy `LAB/LICENSE`)
- Create: `.gitignore`
- Create: `ansible.cfg`
- Create: `ansible/requirements.yaml` (copy `LAB/ansible/requirements.yaml` verbatim)
- Create: `images/.gitkeep`, `persist/.gitkeep`, `share/.gitkeep`, `ansible/inventory/.gitkeep`

**Interfaces:**
- Produces: the directory layout every later task writes into; `persist/` (data disk, kept by destroy), `share/` (host↔guest transfer), `images/` (base image, kept by destroy), `generated/` (per-build, wiped by destroy — created on demand, not committed).

- [ ] **Step 1: Copy the license verbatim**

```bash
cp /Users/henk/Code/infra-utm-redteam-lab/LICENSE LICENSE
```

- [ ] **Step 2: Write `.gitignore`**

```gitignore
# Downloaded base image (large, fetched on demand)
images/*
!images/.gitkeep

# Persistent data disk (large; survives make destroy, never committed)
persist/*
!persist/.gitkeep

# Host<->guest shared folder contents (user files)
share/*
!share/.gitkeep

# Generated per-deploy artifacts
generated/
*.seed.iso

# Ansible inventory generated from running VMs
ansible/inventory/hosts.generated.yaml
!ansible/inventory/.gitkeep

# Secrets and local config
lab.conf
*.pem
id_ed25519
id_ed25519.pub

# Logs
*.log
```

- [ ] **Step 3: Write `ansible.cfg`** (identical to LAB except comments)

```ini
[defaults]
inventory = ansible/inventory/hosts.generated.yaml
remote_user = redteam
private_key_file = ~/.ssh/id_ed25519_redteam
host_key_checking = False
retry_files_enabled = False
interpreter_python = auto_silent
deprecation_warnings = False
roles_path = ansible/roles

[ssh_connection]
pipelining = True
control_path = /tmp/ansible-ssh-%%h-%%p-%%r
```

- [ ] **Step 4: Copy the Galaxy requirements**

```bash
cp /Users/henk/Code/infra-utm-redteam-lab/ansible/requirements.yaml ansible/requirements.yaml
```

- [ ] **Step 5: Create the kept directories**

```bash
mkdir -p images persist share ansible/inventory
touch images/.gitkeep persist/.gitkeep share/.gitkeep ansible/inventory/.gitkeep
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Scaffold repo: license, gitignore, ansible config, directory layout"
```

---

### Task 2: Core library `scripts/lib.sh` + `lab.conf.example` + unit tests

**Files:**
- Create: `scripts/lib.sh` (adapt `LAB/scripts/lib.sh`)
- Create: `lab.conf.example`
- Test: `tests/parse-vm-entry.sh` (copy `LAB/tests/parse-vm-entry.sh`)
- Test: `tests/nic-mode.sh` (new)

**Interfaces:**
- Produces (sourced by every script):
  - `load_config` — sources `lab.conf`, validates, expands `LAB_SSH_KEY`.
  - `vm_name <short>` → `<LAB_PREFIX>-<short>`
  - `priv_key` → private key path
  - `role_image <role>` → always the Kali image path
  - `parse_vm_entry <entry>` → sets globals `VM_SHORT VM_ROLE VM_CPU VM_RAM VM_DISK`
  - `nic_mode` → prints `nat` or `bridged` (default `nat`), dies on anything else
  - `ssh_port_for <index>` → `2200 + index`
  - `data_disk_path` → `${PERSIST_DIR}/data.qcow2`
  - `share_dir` → `${REPO_ROOT}/share`
  - utmctl helpers `vm_exists vm_status stop_vm_and_wait start_vm`, `find_qemu_img`, `disk_bytes`, logging `log ok warn die`, path globals `REPO_ROOT IMAGES_DIR PERSIST_DIR GEN_DIR CLOUDINIT_DIR ANSIBLE_DIR INVENTORY_FILE`.

- [ ] **Step 1: Write the failing test `tests/nic-mode.sh`**

```bash
#!/usr/bin/env bash
# Unit test: nic_mode() validates NET_MODE.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source scripts/lib.sh

fail=0
check() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fail=1; fi
}

# default is nat
unset NET_MODE
check "default nat" "nat" "$(nic_mode)"

NET_MODE=nat
check "explicit nat" "nat" "$(nic_mode)"

NET_MODE=bridged
check "bridged" "bridged" "$(nic_mode)"

# junk exits non-zero
NET_MODE=wan
if ( nic_mode ) >/dev/null 2>&1; then echo "FAIL: junk NET_MODE accepted"; fail=1; else echo "ok: junk NET_MODE rejected"; fi

exit "$fail"
```

- [ ] **Step 2: Run it, expect failure** (lib.sh does not exist yet)

Run: `bash tests/nic-mode.sh`
Expected: FAIL — `scripts/lib.sh: No such file or directory`.

- [ ] **Step 3: Write `scripts/lib.sh`**

Start from `LAB/scripts/lib.sh` and make exactly these changes:
1. Keep the header, `set -euo pipefail`, and the logging block verbatim.
2. **Paths block:** add `PERSIST_DIR="${REPO_ROOT}/persist"` alongside `IMAGES_DIR`.
3. **`require_lab_conf_vars`:** keep the existing required vars (`LAB_PREFIX LAB_USER LAB_SSH_KEY LAB_CPU LAB_RAM LAB_DISK_GB`). Do not require the optional ones (they have defaults below).
4. **`role_image`:** replace the case with Kali-only:

```bash
# Every VM in this repo is Kali; kept as a function so the fleet can grow.
role_image() { echo "${IMAGES_DIR}/${KALI_IMG_FILE}"; }
```

5. Add these helpers after `parse_vm_entry`:

```bash
# --- Networking mode --------------------------------------------------------
# NET_MODE decides the single NIC's mode. 'nat' (default) is the portable
# emulated/SLIRP NIC with a host SSH port-forward; 'bridged' puts the box on
# the physical LAN with its own DHCP address and NO host forward. This is the
# one knob; the security-free single-box design has nothing else to protect.
nic_mode() {
  local m="${NET_MODE:-nat}"
  case "$m" in
    nat|bridged) echo "$m" ;;
    *) die "NET_MODE must be 'nat' or 'bridged', got '${m}'" ;;
  esac
}

# Host SSH port for a VM index (NAT mode only; bridged reaches port 22 on the
# guest's own LAN IP).
SSH_PORT_BASE="${SSH_PORT_BASE:-2200}"
ssh_port_for() { echo "$(( SSH_PORT_BASE + ${1:?index required} )); }" >/dev/null; echo "$(( SSH_PORT_BASE + ${1:?index required} ))"; }

# Persistent data disk kept OUTSIDE the disposable OS lifecycle.
data_disk_path() { echo "${PERSIST_DIR}/data.qcow2"; }

# Host-side shared folder mounted live into the guest.
share_dir() { echo "${REPO_ROOT}/share"; }
```

   NOTE: write `ssh_port_for` as a clean one-liner (the odd form above is illustrative only) — use exactly:

```bash
ssh_port_for() { echo "$(( SSH_PORT_BASE + ${1:?index required} ))"; }
```

6. Keep `require_macos`, `find_qemu_img`, `disk_bytes`, the whole utmctl block (`UTMCTL`, `vm_exists`, `stop_vm_and_wait`, `vm_status`, `start_vm`) verbatim.

- [ ] **Step 4: Run the nic-mode test, expect pass** (config validation is not triggered because the test never calls `load_config`)

Run: `bash tests/nic-mode.sh`
Expected: all `ok:` lines, exit 0.

- [ ] **Step 5: Copy the parser test and run it**

```bash
cp /Users/henk/Code/infra-utm-redteam-lab/tests/parse-vm-entry.sh tests/parse-vm-entry.sh
bash tests/parse-vm-entry.sh
```
Expected: PASS (the parser is copied unchanged in lib.sh).

- [ ] **Step 6: Write `lab.conf.example`**

```bash
# infra-utm-redteam-main configuration
# Copy to lab.conf and adjust. lab.conf is gitignored.

# --- Identity ---------------------------------------------------------------
LAB_PREFIX="redteam"                 # UTM VM name = <LAB_PREFIX>-<name>
LAB_USER="redteam"                   # guest user; Ansible connects as this.
                                     # Avoid a name that is already a guest
                                     # system group (operator, staff, games,
                                     # users); cloud-init handles it, but a free
                                     # name is simpler.
LAB_SSH_KEY="${HOME}/.ssh/id_ed25519_redteam.pub"  # generated by preflight

# --- Networking -------------------------------------------------------------
# nat     : emulated SLIRP NIC. Internet + LAN visibility + a 127.0.0.1 SSH
#           port-forward (make ssh). Portable; works on any Wi-Fi.
# bridged : vmnet-bridged NIC. The box gets its own DHCP IP on the physical
#           LAN (LLMNR/NBNS poisoning, ARP spoof, inbound callbacks). No host
#           port-forward; make ssh uses the discovered LAN IP.
NET_MODE="nat"

# --- Console / desktop ------------------------------------------------------
ATTACKER_PASSWORD="redteam"          # console + LightDM greeter password.
                                     # SSH stays key-only. lab.conf is
                                     # gitignored, so this never lands in git.
ATTACKER_GUI="xfce"                  # xfce (default) | none
CLIPBOARD="yes"                      # SPICE clipboard sharing (yes|no)

# --- Toolset ----------------------------------------------------------------
# curated  : small headless subset
# headless : kali-linux-headless
# default  : kali-linux-default (the standard installer toolset) [default]
# large    : kali-linux-large
KALI_TOOLSET="default"
# Extra kali-tools-* function groups, additive on top of KALI_TOOLSET.
# Space or comma separated, WITHOUT the kali-tools- prefix. Empty = none.
# Groups: top10 web passwords database exploitation forensics fuzzing
#         information-gathering post-exploitation reverse-engineering
#         sniffing-spoofing vulnerability wireless ... (see kali docs).
KALI_TOOL_GROUPS=""

# --- Persistence ------------------------------------------------------------
# A second disk in persist/ that SURVIVES make destroy and is re-attached on
# the next make up, so a rebuild gives a fresh OS with your work intact.
#   data : mounted at /data, with ~/engagements -> /data. Home/dotfiles are
#          CLEAN on every rebuild. [default]
#   home : the persistent disk holds /home, so dotfiles, SSH keys and tool
#          state survive a rebuild too (no clean home on rebuild).
PERSIST_MODE="data"
DATA_DISK_GB=40                      # size at first creation; never shrunk

# --- Resource defaults (per-VM cpu=/ram=/disk= override) --------------------
LAB_CPU=6
LAB_RAM=8192
LAB_DISK_GB=80

# --- Base image (ARM64 / aarch64) -------------------------------------------
# Kali genericcloud, per-release directory (never current/, which 404s on a new
# release). Bump KALI_VERSION to any release at https://kali.download/cloud-images/.
KALI_VERSION="2026.2"
KALI_IMG_URL="https://kali.download/cloud-images/kali-${KALI_VERSION}/kali-linux-${KALI_VERSION}-cloud-genericcloud-arm64.tar.xz"
KALI_SHA_URL="https://kali.download/cloud-images/kali-${KALI_VERSION}/SHA256SUMS"
KALI_IMG_FILE="kali-genericcloud-arm64.raw"

# --- VM fleet ---------------------------------------------------------------
# Single machine. Entry: "name:role [cpu=N] [ram=MiB] [disk=GB]".
# The array is kept so the box can grow into a fleet later.
LAB_VMS=(
  "kali:attacker"
)
```

- [ ] **Step 7: Commit**

```bash
git add scripts/lib.sh lab.conf.example tests/parse-vm-entry.sh tests/nic-mode.sh
git commit -m "Add core lib.sh with net-mode helpers, lab.conf.example, unit tests"
```

---

### Task 3: `Makefile`

**Files:**
- Create: `Makefile` (adapt `LAB/Makefile`)

**Interfaces:**
- Consumes: `scripts/*.sh` (created in later tasks).
- Produces: targets `help preflight up provision configure status ssh console down destroy lint test`.

- [ ] **Step 1: Write `Makefile`**

Start from `LAB/Makefile`. Keep the `ssh`-bare-arg trick verbatim, then extend it to also apply to `console`, and set targets to:

```makefile
# infra-utm-redteam-main
# One-command main Kali attack box on UTM (Apple Silicon).

SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help preflight up provision configure status ssh console down destroy lint test

# Allow `make ssh kali` / `make console kali` (bare VM name) alongside VM=kali.
BAREARG_GOALS := ssh console
ifneq ($(filter $(firstword $(MAKECMDGOALS)),$(BAREARG_GOALS)),)
BARE_ARGS := $(filter-out $(BAREARG_GOALS),$(MAKECMDGOALS))
ifneq ($(BARE_ARGS),)
.PHONY: $(BARE_ARGS)
$(eval $(BARE_ARGS):;@:)
endif
endif

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Full hands-off deploy: preflight, create the VM, configure with Ansible
	@scripts/up.sh

preflight: ## Check macOS, UTM, required tools; generate SSH key
	@scripts/preflight.sh

provision: ## Create and boot the VM only (no Ansible)
	@scripts/up.sh --provision-only

configure: ## Run Ansible against the running VM
	@scripts/up.sh --configure-only

status: ## Show VM status
	@scripts/status.sh

ssh: ## SSH into the box: make ssh kali
	@scripts/ssh.sh $(or $(VM),$(BARE_ARGS))

console: ## Serial console (any kernel): make console kali
	@scripts/console.sh $(or $(VM),$(BARE_ARGS))

down: ## Stop the VM (keeps it)
	@scripts/down.sh

destroy: ## Stop and delete the VM and generated artifacts (persist/ + images/ kept)
	@scripts/destroy.sh

test: ## Run the shell unit tests
	@bash tests/parse-vm-entry.sh
	@bash tests/nic-mode.sh
	@bash tests/persist-roundtrip.sh

lint: ## Syntax-check scripts and Ansible
	@bash -n scripts/*.sh tests/*.sh && echo "shell OK"
	@for f in scripts/*.applescript; do osascript -e "1" >/dev/null; done; echo "applescript present"
	@command -v ansible-lint >/dev/null && ansible-lint ansible/ || echo "ansible-lint not installed, skipping"
```

- [ ] **Step 2: Verify help renders**

Run: `make help`
Expected: the target list prints (targets whose scripts don't exist yet still list fine).

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -m "Add Makefile with up/provision/configure/ssh/console/destroy targets"
```

---

### Task 4: `scripts/preflight.sh`

**Files:**
- Create: `scripts/preflight.sh` (adapt `LAB/scripts/preflight.sh`)

**Interfaces:**
- Consumes: `lib.sh`.
- Produces: tool checks, `${LAB_SSH_KEY%.pub}` keypair if missing, `persist/` + `share/` dirs, `NET_MODE` validation.

- [ ] **Step 1: Write `scripts/preflight.sh`**

Start from `LAB/scripts/preflight.sh` and change:
1. Drop nothing from the tool checks (UTM, qemu-img, ISO tooling, Ansible) — all still needed.
2. After `load_config`, add a NET_MODE check and ensure the kept dirs exist:

```bash
log "Checking NET_MODE"
mode="$(nic_mode)"           # dies on an invalid value
ok "Network mode: ${mode}"

log "Ensuring persist/ and share/ exist"
mkdir -p "$PERSIST_DIR" "$(share_dir)"
ok "persist/ and share/ present"
```

3. In the SSH-key generation branch, `local_priv` is used inside a non-function scope — the LAB version has `local` at top level (works because the block runs in the script body under bash, `local` outside a function errors). Replace `local_priv="$(priv_key)"` with a plain `priv="$(priv_key)"` (no `local`), and update the two following lines to use `$priv`. Change the key comment `-C "redteam-lab"` to `-C "redteam-main"`.

- [ ] **Step 2: Lint**

Run: `bash -n scripts/preflight.sh && echo ok`
Expected: `ok`.

- [ ] **Step 3: Smoke test with a temp config** (no UTM actions happen before the SSH-key step; run in a scratch copy so it doesn't touch your real key)

Run:
```bash
cp lab.conf.example lab.conf
LAB_SSH_KEY=/tmp/pf_test_key.pub bash -c 'source scripts/lib.sh; load_config; nic_mode' && echo "config+nic ok"
rm -f lab.conf
```
Expected: prints `nat` then `config+nic ok`.

- [ ] **Step 4: Commit**

```bash
git add scripts/preflight.sh
git commit -m "Add preflight: tool checks, NET_MODE validation, SSH key generation"
```

---

### Task 5: `scripts/fetch-images.sh` (Kali only)

**Files:**
- Create: `scripts/fetch-images.sh` (adapt `LAB/scripts/fetch-images.sh`)

**Interfaces:**
- Consumes: `lib.sh`, `KALI_*` vars.
- Produces: `images/${KALI_IMG_FILE}` verified, with a `.sha256` sidecar.

- [ ] **Step 1: Write `scripts/fetch-images.sh`**

Start from `LAB/scripts/fetch-images.sh`. Delete the `verify_file`-consumer `fetch_ubuntu` function and its call. Keep `verify_file` (still used by `fetch_kali`) and the whole `fetch_kali` function verbatim. The tail becomes:

```bash
fetch_kali
```

- [ ] **Step 2: Lint**

Run: `bash -n scripts/fetch-images.sh && echo ok`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add scripts/fetch-images.sh
git commit -m "Add fetch-images: download and verify the Kali ARM64 base image"
```

---

### Task 6: cloud-init bootstrap + `scripts/make-seed.sh`

**Files:**
- Create: `cloud-init/kali.user-data.yaml` (adapt `LAB/cloud-init/default.user-data.yaml`)
- Create: `scripts/make-seed.sh` (adapt `LAB/scripts/make-seed.sh`)

**Interfaces:**
- Consumes: `lib.sh`, `LAB_USER`, `LAB_SSH_KEY`.
- Produces: `make-seed.sh <short> <role> <mac>` prints the seed ISO path. The seed's network-config is a single DHCP NIC matched by MAC (works for both nat and bridged). Data-disk formatting/mount is Ansible's job, not cloud-init's.

- [ ] **Step 1: Write `cloud-init/kali.user-data.yaml`**

Copy `LAB/cloud-init/default.user-data.yaml` verbatim — it is already role-agnostic (user, key, no_user_group, ssh_pwauth false, disable_root, apt-periodic-off, python3 + qemu-guest-agent, remote_tmp precreate, growpart/resize_rootfs). No changes needed; rename to `kali.user-data.yaml` so `make-seed.sh` selects it by role→image. (The role is `attacker`; see the template-selection note in Step 2.)

- [ ] **Step 2: Write `scripts/make-seed.sh`**

Start from `LAB/scripts/make-seed.sh` and change:
1. **Signature** → `make-seed.sh <short-name> <role> <mac>` (drop `mac_lab` and `lab_ip` — single NIC now):

```bash
short="${1:?short name required}"
role="${2:?role required}"
mac="${3:?nic mac required}"
```

2. **Template selection:** the box's only role is `attacker`, but its image and cloud-init are Kali. Select the template by filename `kali.user-data.yaml`, falling back to `default.user-data.yaml` if present:

```bash
template="${CLOUDINIT_DIR}/kali.user-data.yaml"
[[ -f "$template" ]] || template="${CLOUDINIT_DIR}/default.user-data.yaml"
[[ -f "$template" ]] || die "No cloud-init template found in ${CLOUDINIT_DIR}"
```

3. **network-config** → a single DHCP NIC matched by MAC:

```bash
cat > "${work}/network-config" <<EOF
version: 2
ethernets:
  primary:
    match:
      macaddress: "${mac}"
    dhcp4: true
EOF
```

4. Keep the `user-data` sed substitution, `meta-data`, and the xorriso/mkisofs/hdiutil seed-building block verbatim.

- [ ] **Step 3: Test the seed builder produces a `cidata` ISO**

Run:
```bash
cp lab.conf.example lab.conf
ssh-keygen -t ed25519 -N "" -f /tmp/seedkey >/dev/null 2>&1 || true
LAB_SSH_KEY=/tmp/seedkey.pub bash -c '
  source scripts/lib.sh; load_config
  LAB_SSH_KEY=/tmp/seedkey.pub
  scripts/make-seed.sh kali attacker 52:54:00:AA:00:01' | tail -1
rm -f lab.conf
```
Expected: prints a path ending `generated/redteam-kali.seed.iso` and the file exists. (You can confirm the volume label is `cidata` with `hdiutil imageinfo` on macOS if desired.)

- [ ] **Step 4: Commit**

```bash
git add cloud-init/kali.user-data.yaml scripts/make-seed.sh
git commit -m "Add Kali cloud-init bootstrap and single-NIC seed builder"
```

---

### Task 7: `scripts/create-vm.applescript` + `scripts/vm-config.applescript`

**Files:**
- Create: `scripts/create-vm.applescript` (new — based on ANON's per-mode NIC pattern)
- Create: `scripts/vm-config.applescript` (adapt `LAB/scripts/vm-config.applescript`, add a `datadisk` op)

**Interfaces:**
- Produces:
  - `create-vm.applescript <name> <diskPath> <seedPath> <memMiB> <cpu> <mac> <sshPort> <netMode> <dataDiskPath|""> <sharePath|"">` → prints the new VM id.
  - `vm-config.applescript get <name>` → `"<cpu> <ram>"`; `set <name> <cpu> <ram>` → `ok`; `datadisk <name>` → the in-bundle path of the 3rd drive (the data disk), or empty.

- [ ] **Step 1: Write `scripts/create-vm.applescript`**

```applescript
-- Create one QEMU aarch64 Kali VM in UTM.
--
-- ONE NIC, mode chosen by netMode:
--   "nat"     : "emulated" (QEMU user/SLIRP) with a 127.0.0.1 SSH port-forward.
--               The hostfwd works ONLY on "emulated"; UTM "shared"/vmnet modes
--               silently drop port forwards.
--   "bridged" : "bridged" (vmnet-bridged) -- the box gets its own DHCP address
--               on the physical LAN. No port-forward is possible here.
--
-- Optional 3rd drive: the persistent data disk (kept in persist/). Optional
-- directory share: the host-side share/ folder.
--
-- This and vm-config.applescript are the ONLY UTM integration points. Property
-- names follow the UTM scripting dictionary (docs.getutm.app/scripting/reference).
-- If a UTM version rejects a key, adjust it here only. See Step 3 validation.
on run argv
	set vmName to item 1 of argv
	set diskPath to item 2 of argv
	set seedPath to item 3 of argv
	set memMiB to (item 4 of argv) as integer
	set cpuCores to (item 5 of argv) as integer
	set macAddr to item 6 of argv
	set sshPort to (item 7 of argv) as integer
	set netMode to item 8 of argv
	set dataDiskPath to item 9 of argv
	set sharePath to item 10 of argv

	set diskFile to POSIX file diskPath
	set seedFile to POSIX file seedPath

	tell application "UTM"
		-- NIC per mode.
		if netMode is "bridged" then
			set nics to {{mode:bridged, address:macAddr}}
		else
			set nics to {{mode:emulated, address:macAddr, port forwards:{{host address:"127.0.0.1", host port:sshPort, guest port:22}}}}
		end if

		-- Drives: OS + seed (non-removable so UTM uses VirtIO, not a USB CD-ROM
		-- that hangs boot on UTM 4.7.x), plus the optional data disk as a 3rd
		-- non-removable VirtIO drive.
		if dataDiskPath is not "" then
			set theDrives to {{removable:false, source:diskFile}, {removable:false, source:seedFile}, {removable:false, source:(POSIX file dataDiskPath)}}
		else
			set theDrives to {{removable:false, source:diskFile}, {removable:false, source:seedFile}}
		end if

		set cfg to {name:vmName, architecture:"aarch64", uefi:true, memory:memMiB, cpu cores:cpuCores, drives:theDrives, displays:{{hardware:"virtio-gpu-pci"}}, network interfaces:nics}

		-- Optional host directory share. The exact key is confirmed by the Step 3
		-- validation; if UTM's dictionary names it differently, change it here.
		if sharePath is not "" then
			set cfg to cfg & {directory shares:{{source:(POSIX file sharePath)}}}
		end if

		set vm to make new virtual machine with properties {backend:qemu, configuration:cfg}
		return id of vm
	end tell
end run
```

- [ ] **Step 2: Write `scripts/vm-config.applescript`**

Start from `LAB/scripts/vm-config.applescript`. Keep `get` and `set` verbatim. Add a `datadisk` branch that returns the source path of the third drive (the persistent data disk), used by `destroy.sh` to copy it back out:

```applescript
		else if op is "datadisk" then
			set cfg to configuration of vm
			set ds to drives of cfg
			if (count of ds) < 3 then return ""
			return POSIX path of (source of (item 3 of ds))
```

Insert this branch before the final `else error ...` line.

- [ ] **Step 3: First-run validation of the two uncertain UTM keys**

These two keys are UTM-version-dependent and are the spec's flagged first-run items. After a real `make provision` (Task 8+), confirm:
1. **Data disk visible in guest:** `make ssh kali` then `lsblk` shows a second disk (e.g. `vdb`) of `DATA_DISK_GB`. If the `drives` list rejects a 3rd non-removable entry, adjust the drive record in `create-vm.applescript`.
2. **Directory share:** if UTM rejects `directory shares`, open the UTM scripting dictionary (Script Editor → File → Open Dictionary → UTM) to find the correct property, fix it here, and re-provision. Fallback if scripting does not expose shares: document enabling the VirtFS/SPICE share once in the UTM GUI (VM → Edit → Sharing), which persists in the bundle. Record the outcome in `docs/host-integration.md`.

This step has no commit of its own; fixes land in the file and are committed with Task 8's validation.

- [ ] **Step 4: Syntax-check both scripts**

Run:
```bash
osacompile -o /tmp/cv.scpt scripts/create-vm.applescript && echo "create-vm ok"
osacompile -o /tmp/vc.scpt scripts/vm-config.applescript && echo "vm-config ok"
rm -f /tmp/cv.scpt /tmp/vc.scpt
```
Expected: both `ok` (compiles = syntactically valid; semantic key validation is Step 3).

- [ ] **Step 5: Commit**

```bash
git add scripts/create-vm.applescript scripts/vm-config.applescript
git commit -m "Add UTM provisioning AppleScript: per-mode NIC, data disk, directory share"
```

---

### Task 8: `scripts/create-vm.sh`

**Files:**
- Create: `scripts/create-vm.sh` (adapt `LAB/scripts/create-vm.sh`)

**Interfaces:**
- Consumes: `lib.sh`, `create-vm.applescript`, `vm-config.applescript`, `make-seed.sh`.
- Produces: `create-vm.sh <index> <short> <role> <cpu> <ram> <disk_gb>` creates/reconciles the VM and prints one line: `<name> <ssh_port> <net_mode>` (ssh_port is `0` in bridged mode). Ensures `persist/data.qcow2` exists at `DATA_DISK_GB` before first creation.

- [ ] **Step 1: Write `scripts/create-vm.sh`**

Start from `LAB/scripts/create-vm.sh` and make these changes:
1. **MAC/port/mode setup** (replace the `mac_nat/mac_lab/lab_ip/ssh_port` block):

```bash
name="$(vm_name "$short")"
mac="$(printf '52:54:00:AA:00:%02X' "$idx")"
mode="$(nic_mode)"
if [[ "$mode" == "nat" ]]; then
  ssh_port="$(ssh_port_for "$idx")"
else
  ssh_port=0
fi
```

2. **Keep `reconcile_existing_vm` almost verbatim** — cpu/ram reconcile and the disk compare-and-warn are unchanged. It never touches the data disk (which lives in the bundle once created). At the end of the existing-VM branch, change the emitted line:

```bash
if vm_exists "$name"; then
  reconcile_existing_vm "$cpu" "$ram" "$disk_gb"
  echo "${name} ${ssh_port} ${mode}"
  exit 0
fi
```

3. **Disk prep** (the `role_image`, `qemu-img info`, APFS clone, resize block) stays verbatim — `role_image` now always returns the Kali raw image.

4. **Ensure the persistent data disk exists** before creating the VM (right after the OS disk resize block):

```bash
# Persistent data disk: created once, kept in persist/ across make destroy, and
# re-imported by UTM on every (re)creation. Never resized down; grown only by
# recreating. DATA_DISK_GB defaults to 40.
data_disk="$(data_disk_path)"
if [[ ! -f "$data_disk" ]]; then
  mkdir -p "$PERSIST_DIR"
  log "Creating persistent data disk ${data_disk} (${DATA_DISK_GB:-40}G)"
  "$QEMU_IMG" create -f qcow2 "$data_disk" "${DATA_DISK_GB:-40}G" >/dev/null
fi
```

5. **Seed build** → single MAC arg:

```bash
seed="$("$(dirname "${BASH_SOURCE[0]}")/make-seed.sh" "$short" "$role" "$mac" | tail -1)"
```

6. **Create call** → new argument list (with data disk + share dir):

```bash
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

echo "${name} ${ssh_port} ${mode}"
```

- [ ] **Step 2: Lint**

Run: `bash -n scripts/create-vm.sh && echo ok`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add scripts/create-vm.sh
git commit -m "Add create-vm: net-mode NIC, persistent data disk, shared folder"
```

---

### Task 9: Persistence round-trip — `scripts/destroy.sh` + `tests/persist-roundtrip.sh`

**Files:**
- Create: `scripts/destroy.sh` (adapt `LAB/scripts/destroy.sh`)
- Test: `tests/persist-roundtrip.sh` (new)
- Create: `scripts/persist-lib.sh` (new — the pure decision logic, unit-testable without UTM)

**Interfaces:**
- Produces:
  - `persist_action <persist_disk_exists:0|1>` → prints `create` (no disk yet) or `reuse` (disk present). This is the create-time decision `create-vm.sh` embodies; unit-tested here.
  - `destroy.sh` copies the VM's in-bundle data disk back to `persist/data.qcow2` before deleting the VM, so work survives. `persist/` and `images/` are kept.

- [ ] **Step 1: Write the failing test `tests/persist-roundtrip.sh`**

```bash
#!/usr/bin/env bash
# Unit test: the persistence decision — create the data disk only when absent,
# reuse it when present (so make destroy + up preserves work).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source scripts/persist-lib.sh

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fail=1; fi; }

check "absent disk -> create" "create" "$(persist_action 0)"
check "present disk -> reuse" "reuse"  "$(persist_action 1)"

exit "$fail"
```

- [ ] **Step 2: Run it, expect failure**

Run: `bash tests/persist-roundtrip.sh`
Expected: FAIL — `scripts/persist-lib.sh: No such file or directory`.

- [ ] **Step 3: Write `scripts/persist-lib.sh`**

```bash
#!/usr/bin/env bash
# Pure persistence decisions, sourced by create-vm.sh and destroy.sh. No UTM,
# no side effects, so it is unit-testable on any machine.
set -euo pipefail

# Decide whether to create a fresh data disk or reuse the existing one.
# Arg: 1 if persist/data.qcow2 exists, 0 if not.
persist_action() {
  case "${1:?exists flag required}" in
    0) echo "create" ;;
    *) echo "reuse" ;;
  esac
}
```

- [ ] **Step 4: Run the test, expect pass**

Run: `bash tests/persist-roundtrip.sh`
Expected: both `ok:` lines, exit 0.

- [ ] **Step 5: Write `scripts/destroy.sh`**

Start from `LAB/scripts/destroy.sh`. Keep the confirmation prompt (single VM now). Before deleting each VM, copy its in-bundle data disk back to `persist/`:

```bash
for entry in "${LAB_VMS[@]}"; do
  parse_vm_entry "$entry"
  name="$(vm_name "$VM_SHORT")"

  # Preserve the persistent data disk: UTM imported persist/data.qcow2 into the
  # VM bundle at creation, so the LIVE data is the bundle copy, not persist/.
  # Copy it back out before deleting the VM, so a rebuild re-imports current
  # work. Best-effort: a failure here must not block teardown, but is warned.
  if vm_exists "$name"; then
    bundle_disk="$(osascript "${REPO_ROOT}/scripts/vm-config.applescript" datadisk "$name" 2>/dev/null || true)"
    if [[ -n "$bundle_disk" && -f "$bundle_disk" ]]; then
      log "Preserving data disk from ${name} -> $(data_disk_path)"
      mkdir -p "$PERSIST_DIR"
      cp "$bundle_disk" "$(data_disk_path).new" \
        && mv -f "$(data_disk_path).new" "$(data_disk_path)" \
        && ok "Data disk preserved" \
        || warn "Could not preserve data disk from ${name}; persist/ left as-is"
    else
      warn "${name}: no data disk found in its bundle to preserve"
    fi
  fi

  log "Stopping and deleting ${name}"
  stop_vm_and_wait "$name" 30 || warn "${name} did not stop in time, trying to delete anyway"
  "$UTMCTL" delete "$name" 2>/dev/null \
    || osascript -e "tell application \"UTM\" to delete virtual machine named \"${name}\"" 2>/dev/null \
    || warn "Could not delete ${name} (already gone?)"
done

log "Removing generated artifacts"
rm -rf "$GEN_DIR"
rm -f "$INVENTORY_FILE"
ok "Box destroyed. Base image kept in images/, work kept in persist/."
```

- [ ] **Step 6: Lint + run tests**

Run: `bash -n scripts/destroy.sh && bash tests/persist-roundtrip.sh && echo ok`
Expected: `ok:` lines then `ok`.

- [ ] **Step 7: Commit**

```bash
git add scripts/persist-lib.sh scripts/destroy.sh tests/persist-roundtrip.sh
git commit -m "Add persistence round-trip: preserve data disk across destroy, with unit test"
```

---

### Task 10: `scripts/up.sh` + `scripts/gen-inventory.sh` + `scripts/wait-ssh.sh`

**Files:**
- Create: `scripts/wait-ssh.sh` (copy `LAB/scripts/wait-ssh.sh` verbatim)
- Create: `scripts/gen-inventory.sh` (adapt `LAB/scripts/gen-inventory.sh`)
- Create: `scripts/up.sh` (adapt `LAB/scripts/up.sh`)

**Interfaces:**
- Consumes: all scripts above. `create-vm.sh` emits `<name> <ssh_port> <mode>`.
- Produces: a booted, SSH-reachable, Ansible-configured box. `gen-inventory.sh` reads stdin rows `<short> <name> <host> <port>` and writes the inventory. In bridged mode the host is the discovered LAN IP and the port is 22.

- [ ] **Step 1: Copy `wait-ssh.sh` verbatim**

```bash
cp /Users/henk/Code/infra-utm-redteam-lab/scripts/wait-ssh.sh scripts/wait-ssh.sh
```

- [ ] **Step 2: Write `scripts/gen-inventory.sh`**

Start from `LAB/scripts/gen-inventory.sh`. Simplify to rows `<short> <name> <host> <port>` (no `lab_ip`, single role group `role_attacker`). Replace the host-writing and group blocks:

```bash
rows="$(cat)"
{
  echo "# Generated by scripts/gen-inventory.sh. Do not edit by hand."
  echo "all:"
  echo "  vars:"
  echo "    ansible_user: ${LAB_USER}"
  echo "    ansible_ssh_common_args: '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'"
  echo "  hosts:"
  while read -r short name host port; do
    [[ -z "$short" ]] && continue
    echo "    ${short}:"
    echo "      ansible_host: ${host}"
    echo "      ansible_port: ${port}"
    echo "      vm_name: ${name}"
  done <<<"$rows"
  echo "  children:"
  echo "    role_attacker:"
  echo "      hosts:"
  while read -r short name host port; do
    [[ -z "$short" ]] && continue
    echo "        ${short}:"
  done <<<"$rows"
} > "$INVENTORY_FILE"
ok "Inventory written: ${INVENTORY_FILE}"
```

- [ ] **Step 3: Write `scripts/up.sh`**

Start from `LAB/scripts/up.sh` and change:
1. **`run_ansible`** — pass the box's variables. Keep the secure password-via-0600-file mechanism verbatim; extend the plain `-e` list:

```bash
  ( cd "$REPO_ROOT" && ansible-playbook "${ANSIBLE_DIR}/playbook.yaml" \
      -e "attacker_toolset=${KALI_TOOLSET:-default}" \
      -e "attacker_gui=${ATTACKER_GUI:-xfce}" \
      -e "attacker_clipboard=${CLIPBOARD:-yes}" \
      -e "persist_mode=${PERSIST_MODE:-data}" \
      -e "kali_tool_groups=${KALI_TOOL_GROUPS:-}" \
      -e "@${vars_file}" )
```
   (The `vars_file` still carries `attacker_password`.)

2. **Provisioning loop + SSH wait** — resolve each VM's SSH endpoint by mode. Replace the provisioning/wait/inventory section:

```bash
"${SCRIPTS}/preflight.sh"
"${SCRIPTS}/fetch-images.sh"

mode="$(nic_mode)"
log "Provisioning ${#LAB_VMS[@]} VM(s) in ${mode} mode"
rows=""                # lines: short name host port
idx=0
for entry in "${LAB_VMS[@]}"; do
  idx=$((idx + 1))
  parse_vm_entry "$entry"
  result="$("${SCRIPTS}/create-vm.sh" "$idx" "$VM_SHORT" "$VM_ROLE" \
    "$VM_CPU" "$VM_RAM" "$VM_DISK" | tail -1)"
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
  rows+="${VM_SHORT} ${name} ${host} ${port}"$'\n'
done

log "Waiting for VMs to accept SSH"
while read -r short name host port; do
  [[ -z "$short" ]] && continue
  "${SCRIPTS}/wait-ssh.sh" "$host" "$port" 420
done <<<"$rows"

printf '%s' "$rows" | "${SCRIPTS}/gen-inventory.sh"
```

3. **Final message:**

```bash
run_ansible
echo
ok "Box is up. Try: make ssh kali"
```

- [ ] **Step 4: Lint**

Run: `bash -n scripts/up.sh scripts/gen-inventory.sh scripts/wait-ssh.sh && echo ok`
Expected: `ok`.

- [ ] **Step 5: Test inventory generation without UTM**

Run:
```bash
cp lab.conf.example lab.conf
printf 'kali redteam-kali 127.0.0.1 2201\n' | bash -c 'source scripts/lib.sh; load_config; scripts/gen-inventory.sh'
cat ansible/inventory/hosts.generated.yaml
rm -f lab.conf ansible/inventory/hosts.generated.yaml
```
Expected: a valid inventory with host `kali`, `ansible_host: 127.0.0.1`, `ansible_port: 2201`, group `role_attacker`.

- [ ] **Step 6: Commit**

```bash
git add scripts/up.sh scripts/gen-inventory.sh scripts/wait-ssh.sh
git commit -m "Add orchestrator: provision, bridged IP discovery, inventory, Ansible run"
```

---

### Task 11: Access + lifecycle scripts — `ssh.sh`, `console.sh`, `status.sh`, `down.sh`

**Files:**
- Create: `scripts/ssh.sh` (adapt `LAB/scripts/ssh.sh`)
- Create: `scripts/console.sh` (copy `ANON/scripts/console.sh` verbatim)
- Create: `scripts/status.sh` (copy `LAB/scripts/status.sh` verbatim)
- Create: `scripts/down.sh` (copy `LAB/scripts/down.sh` verbatim)

**Interfaces:**
- Consumes: `lib.sh`, the generated inventory (for bridged host lookup).
- Produces: `make ssh kali`, `make console kali`, `make status`, `make down`.

- [ ] **Step 1: Write `scripts/ssh.sh`**

Start from `LAB/scripts/ssh.sh`. Keep the fleet-index lookup. After computing `idx`, branch on mode. In bridged mode, read the host from the generated inventory (written by the last `make up`); fall back to `utmctl ip-address`:

```bash
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
```

- [ ] **Step 2: Copy the other three verbatim**

```bash
cp /Users/henk/Code/infra-utm-anon-egress/scripts/console.sh scripts/console.sh
cp /Users/henk/Code/infra-utm-redteam-lab/scripts/status.sh scripts/status.sh
cp /Users/henk/Code/infra-utm-redteam-lab/scripts/down.sh scripts/down.sh
```

- [ ] **Step 3: Lint**

Run: `bash -n scripts/ssh.sh scripts/console.sh scripts/status.sh scripts/down.sh && echo ok`
Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add scripts/ssh.sh scripts/console.sh scripts/status.sh scripts/down.sh
git commit -m "Add access and lifecycle scripts: ssh (nat/bridged), console, status, down"
```

---

### Task 12: Ansible playbook, group_vars, common role

**Files:**
- Create: `ansible/playbook.yaml`
- Create: `ansible/group_vars/all.yaml` (copy `LAB/ansible/group_vars/all.yaml` verbatim)
- Create: `ansible/group_vars/role_attacker.yaml`
- Create: `ansible/roles/common/tasks/main.yaml` (adapt `LAB/ansible/roles/common/tasks/main.yaml`)

**Interfaces:**
- Produces: one play running `common` then `attacker` on the box. Variables consumed by the role: `attacker_toolset`, `attacker_gui`, `attacker_clipboard`, `attacker_password`, `persist_mode`, `kali_tool_groups`.

- [ ] **Step 1: Write `ansible/playbook.yaml`**

```yaml
---
# Configures the main Kali attack box after provisioning. Idempotent.
# Subsets via tags, e.g. --tags toolset or --tags desktop.

- name: Base configuration
  hosts: all
  become: true
  gather_facts: true
  roles:
    - role: common
      tags: [common, base]

- name: Configure the attack box
  hosts: role_attacker
  become: true
  roles:
    - role: attacker
      tags: [attacker]
```

- [ ] **Step 2: Copy `group_vars/all.yaml` verbatim**

```bash
cp /Users/henk/Code/infra-utm-redteam-lab/ansible/group_vars/all.yaml ansible/group_vars/all.yaml
```

- [ ] **Step 3: Write `ansible/group_vars/role_attacker.yaml`**

```yaml
---
# Toolset selection. up.sh passes -e attacker_toolset from KALI_TOOLSET.
attacker_toolset: default

attacker_packages_curated:
  - nmap
  - netcat-traditional
  - gobuster
  - ffuf
  - hydra
  - sqlmap
  - metasploit-framework
  - seclists
attacker_packages_headless:
  - kali-linux-headless
attacker_packages_default:
  - kali-linux-default
attacker_packages_large:
  - kali-linux-large

attacker_packages: >-
  {{ attacker_packages_curated if attacker_toolset == 'curated'
     else attacker_packages_headless if attacker_toolset == 'headless'
     else attacker_packages_large if attacker_toolset == 'large'
     else attacker_packages_default }}

# Extra kali-tools-* groups, additive on top of the toolset. up.sh passes
# -e kali_tool_groups from KALI_TOOL_GROUPS (space/comma separated, no prefix).
kali_tool_groups: ""

# Desktop and console. up.sh passes these from lab.conf.
attacker_gui: xfce
attacker_clipboard: "yes"
attacker_password: redteam

# Persistence layout. up.sh passes -e persist_mode from PERSIST_MODE.
#   data -> mount the data disk at /data (~/engagements -> /data), clean home
#   home -> the data disk holds /home
persist_mode: data
```

- [ ] **Step 4: Write `ansible/roles/common/tasks/main.yaml`**

Start from `LAB/ansible/roles/common/tasks/main.yaml`. Keep timezone + common packages. Change the MOTD text:

```yaml
- name: Deploy MOTD
  ansible.builtin.copy:
    dest: /etc/motd
    mode: "0644"
    content: |+

      ════════════════════════════════════════
        redteam · main Kali attack box · {{ inventory_hostname }}
        Authorised use only.
      ════════════════════════════════════════

```

- [ ] **Step 5: Lint**

Run: `command -v ansible-lint >/dev/null && ansible-lint ansible/playbook.yaml ansible/roles/common/ || echo "ansible-lint not installed, skipping"`
Expected: clean, or the skip message.

- [ ] **Step 6: Commit**

```bash
git add ansible/playbook.yaml ansible/group_vars/all.yaml ansible/group_vars/role_attacker.yaml ansible/roles/common/tasks/main.yaml
git commit -m "Add Ansible playbook, group_vars, common role"
```

---

### Task 13: The `attacker` role

**Files:**
- Create: `ansible/roles/attacker/tasks/main.yaml`
- Create: `ansible/roles/attacker/tasks/toolset.yaml`
- Create: `ansible/roles/attacker/tasks/console-kernel.yaml`
- Create: `ansible/roles/attacker/tasks/console-auth.yaml`
- Create: `ansible/roles/attacker/tasks/desktop.yaml`
- Create: `ansible/roles/attacker/tasks/integration.yaml`
- Create: `ansible/roles/attacker/handlers/main.yaml`

**Interfaces:**
- Consumes: variables from `role_attacker.yaml` + `-e` overrides.
- Produces: a fully configured box. Ordering is load-bearing (kernel → flush reboot → desktop → integration → toolset), mirroring ANON's hard-won lessons.

- [ ] **Step 1: Write `tasks/main.yaml` (orchestration)**

```yaml
---
# Order is load-bearing: swap to the console kernel and reboot BEFORE the
# desktop (a greeter needs the standard kernel's framebuffer); set the console
# password; install the desktop; wire host integration and mounts; install the
# toolset last (it can pull GUI apps and is the slowest step).
- name: Console kernel + console security
  ansible.builtin.include_tasks: console-kernel.yaml
  tags: [kernel]

- name: Apply any pending kernel reboot before the desktop
  ansible.builtin.meta: flush_handlers

- name: Console / GUI password
  ansible.builtin.include_tasks: console-auth.yaml
  tags: [auth]

- name: Desktop
  ansible.builtin.include_tasks: desktop.yaml
  when: attacker_gui | default('xfce') != 'none'
  tags: [desktop, gui]

- name: Host integration and persistent mounts
  ansible.builtin.include_tasks: integration.yaml
  tags: [integration, mounts]

- name: Kali toolset
  ansible.builtin.include_tasks: toolset.yaml
  tags: [toolset, tools]
```

- [ ] **Step 2: Write `tasks/console-kernel.yaml`**

Adapt from `LAB/ansible/roles/attacker/tasks/main.yaml` — the kernel-swap and autologin-removal parts (drop the toolset/hosts/msfdb parts, which move elsewhere):

```yaml
---
# Kali genericcloud runs a cloud kernel with no virtio_gpu/DRM, so UTM's display
# stays blank. Install the standard kernel and make grub default to it; keep the
# cloud kernel as a fallback (purging it wedges boot). Driven over SSH; the
# console/desktop is the payoff.
- name: Install the standard Kali kernel (virtio_gpu for the console)
  ansible.builtin.apt:
    name: linux-image-arm64
    state: present
    update_cache: true
    cache_valid_time: 3600
  when: ansible_distribution == 'Kali'

- name: Make grub default to the standard (non-cloud) kernel
  ansible.builtin.shell: |
    set -euo pipefail
    update-grub
    sub="$(awk -F"'" '/^submenu / {print $4; exit}' /boot/grub/grub.cfg)"
    entry="$(awk -F"'" '/[[:space:]]menuentry / && /gnulinux/ && /kali-arm64/ && !/cloud/ && !/recovery/ {print $4; exit}' /boot/grub/grub.cfg)"
    [ -n "$entry" ] || { echo "no standard-kernel grub entry found"; exit 1; }
    if ! grep -q '^GRUB_DEFAULT=saved' /etc/default/grub; then
      sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
      grep -q '^GRUB_DEFAULT=' /etc/default/grub || echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
    fi
    update-grub
    if [ -n "$sub" ]; then grub-set-default "${sub}>${entry}"; else grub-set-default "${entry}"; fi
  args:
    executable: /bin/bash
  changed_when: false
  when: ansible_distribution == 'Kali'

- name: Reboot into the standard kernel to activate the UTM console
  ansible.builtin.reboot:
    reboot_timeout: 300
  when:
    - ansible_distribution == 'Kali'
    - "'cloud' in ansible_kernel"

- name: Remove the Kali image's console auto-login overrides
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - /etc/systemd/system/getty@tty1.service.d/autologin.conf
    - /etc/systemd/system/serial-getty@.service.d/autologin.conf
  notify: Reload systemd and restart the tty1 getty
```

- [ ] **Step 3: Write `tasks/console-auth.yaml`**

```yaml
---
# Set the console/GUI password on the guest (also unlocks the account cloud-init
# locked, so the LightDM greeter is usable). SSH stays key-only regardless.
- name: Set the user's console/GUI password
  ansible.builtin.shell:
    cmd: "set -o pipefail; echo '{{ ansible_user }}:{{ attacker_password }}' | chpasswd"
    executable: /bin/bash
  changed_when: false
  no_log: true
```

- [ ] **Step 4: Write `tasks/desktop.yaml`**

Adapt from `LAB/ansible/roles/desktop/tasks/main.yaml` (LightDM greeter, no auto-login, graphical target). This role runs after the kernel flush, so LightDM can start immediately:

```yaml
---
# XFCE desktop rendered in UTM's window, LightDM greeter that prompts for
# ATTACKER_PASSWORD (never auto-logs in). Runs after the console-kernel reboot.
- name: Preseed LightDM as the default display manager
  ansible.builtin.debconf:
    name: lightdm
    question: shared/default-x-display-manager
    vtype: select
    value: lightdm

- name: Install the XFCE desktop and LightDM
  ansible.builtin.apt:
    name:
      - kali-desktop-xfce
      - lightdm
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Remove any LightDM auto-login drop-in
  ansible.builtin.file:
    path: /etc/lightdm/lightdm.conf.d/10-autologin.conf
    state: absent

- name: Remove the user from passwordless-login groups
  ansible.builtin.shell:
    cmd: |
      set -euo pipefail
      for g in nopasswdlogin autologin; do
        if getent group "$g" >/dev/null && id -nG "{{ ansible_user }}" | tr ' ' '\n' | grep -qx "$g"; then
          gpasswd -d "{{ ansible_user }}" "$g"
        fi
      done
    executable: /bin/bash
  register: desktop_group_removal
  changed_when: "'Removing user' in desktop_group_removal.stdout"

- name: Read the current default systemd target
  ansible.builtin.command: systemctl get-default
  register: desktop_current_target
  changed_when: false

- name: Boot to the graphical target by default
  ansible.builtin.command: systemctl set-default graphical.target
  changed_when: true
  when: desktop_current_target.stdout | trim != 'graphical.target'

- name: Enable and start LightDM
  ansible.builtin.systemd:
    name: lightdm
    enabled: true
    state: started
```

- [ ] **Step 5: Write `tasks/integration.yaml`**

```yaml
---
# Host integration: SPICE clipboard, the live shared folder, and the persistent
# data disk mounted per persist_mode. No anonymity invariant here, so these are
# all fine.

# --- Clipboard (SPICE) ------------------------------------------------------
- name: Install or remove the SPICE guest agent (clipboard)
  ansible.builtin.apt:
    name: spice-vdagent
    state: "{{ 'present' if (attacker_clipboard | default('yes') | bool) else 'absent' }}"
    purge: true
    update_cache: true
    cache_valid_time: 3600

- name: Enable the SPICE agent daemon
  ansible.builtin.systemd_service:
    name: spice-vdagentd
    enabled: true
    state: started
  when: attacker_clipboard | default('yes') | bool

# --- Shared folder ----------------------------------------------------------
# UTM exposes the host share/ over VirtFS (9p, tag typically "share") or SPICE
# WebDAV. Mount 9p if the guest sees the tag; otherwise leave a note. Confirmed
# by the Task 7 Step 3 validation.
- name: Ensure the shared-folder mount point exists
  ansible.builtin.file:
    path: "/home/{{ ansible_user }}/share"
    state: directory
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: "0755"

- name: Mount the UTM shared folder over 9p (if present)
  ansible.posix.mount:
    path: "/home/{{ ansible_user }}/share"
    src: share
    fstype: 9p
    opts: "trans=virtio,version=9p2000.L,rw,_netdev,nofail,msize=104857600"
    state: mounted
  register: share_mount
  failed_when: false

# --- Persistent data disk ---------------------------------------------------
# The second VirtIO disk (persist/data.qcow2, imported by UTM). Format on first
# use, then mount at /data (persist_mode=data) or /home (persist_mode=home).
- name: Identify the data disk (the non-root VirtIO block device)
  ansible.builtin.shell:
    cmd: |
      set -euo pipefail
      root_src="$(findmnt -no SOURCE / | sed 's/[0-9]*$//; s/p$//')"
      for d in /dev/vdb /dev/vdc /dev/vda; do
        [ -b "$d" ] || continue
        case "$root_src" in *"$d"*) continue;; esac
        echo "$d"; exit 0
      done
      exit 0
  args:
    executable: /bin/bash
  register: data_dev
  changed_when: false

- name: Fail clearly if no data disk is present
  ansible.builtin.fail:
    msg: >-
      persist_mode={{ persist_mode }} but no second VirtIO disk was found.
      The data disk is created by scripts/create-vm.sh; rebuild with make destroy
      then make up, or confirm the Task 7 data-disk validation.
  when: (data_dev.stdout | trim) | length == 0

- name: Make an ext4 filesystem on the data disk if it has none
  ansible.builtin.filesystem:
    fstype: ext4
    dev: "{{ data_dev.stdout | trim }}"
    # never force: only formats a disk that has no filesystem yet, so existing
    # work is never wiped on a reconfigure.
  when: (data_dev.stdout | trim) | length > 0

- name: Mount the data disk at /data
  ansible.posix.mount:
    path: /data
    src: "{{ data_dev.stdout | trim }}"
    fstype: ext4
    opts: "defaults,nofail"
    state: mounted
  when:
    - (data_dev.stdout | trim) | length > 0
    - persist_mode | default('data') == 'data'

- name: Link ~/engagements to /data
  ansible.builtin.file:
    src: /data
    dest: "/home/{{ ansible_user }}/engagements"
    state: link
    force: true
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
  when: persist_mode | default('data') == 'data'

- name: Own /data for the user
  ansible.builtin.file:
    path: /data
    state: directory
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: "0755"
  when:
    - (data_dev.stdout | trim) | length > 0
    - persist_mode | default('data') == 'data'

- name: Mount the data disk at /home (persist_mode=home)
  ansible.posix.mount:
    path: /home
    src: "{{ data_dev.stdout | trim }}"
    fstype: ext4
    opts: "defaults,nofail"
    state: mounted
  when:
    - (data_dev.stdout | trim) | length > 0
    - persist_mode | default('data') == 'home'
  # NOTE: on a fresh data disk this mounts an empty /home OVER the cloud-init
  # user's home. The Task 7 validation confirms the first-boot ordering; if the
  # login user's home must be seeded, copy /etc/skel after mount. Documented in
  # docs/host-integration.md.
```

- [ ] **Step 6: Write `tasks/toolset.yaml`**

Adapt from `LAB/ansible/roles/attacker/tasks/main.yaml` toolset + msfdb parts, and add additive tool groups:

```yaml
---
- name: Install the selected Kali toolset
  ansible.builtin.apt:
    name: "{{ attacker_packages }}"
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Normalise the extra tool-group list
  ansible.builtin.set_fact:
    attacker_tool_group_list: >-
      {{ (kali_tool_groups | default('') | regex_replace(',', ' ')).split()
         | map('regex_replace', '^(.*)$', 'kali-tools-\1') | list }}

- name: Install extra Kali tool groups (additive)
  ansible.builtin.apt:
    name: "{{ attacker_tool_group_list }}"
    state: present
    update_cache: true
    cache_valid_time: 3600
  when: attacker_tool_group_list | length > 0

- name: Check for the Metasploit database helper
  ansible.builtin.stat:
    path: /usr/bin/msfdb
  register: attacker_msfdb

- name: Initialise the Metasploit database
  ansible.builtin.command: msfdb init
  args:
    creates: /usr/share/metasploit-framework/config/database.yml
  when: attacker_msfdb.stat.exists

- name: Keep PostgreSQL running across reboots (Metasploit backend)
  ansible.builtin.service:
    name: postgresql
    enabled: true
    state: started
  when: attacker_msfdb.stat.exists
```

- [ ] **Step 7: Write `handlers/main.yaml`**

```yaml
---
- name: Reload systemd and restart the tty1 getty
  ansible.builtin.systemd:
    daemon_reload: true
    name: getty@tty1.service
    state: restarted
```

- [ ] **Step 8: Add `ansible.posix` to Galaxy requirements**

`integration.yaml` uses `ansible.posix.mount`. Add to `ansible/requirements.yaml`:

```yaml
  - name: ansible.posix
    version: ">=1.5.0,<3.0.0"
```

- [ ] **Step 9: Lint the whole role**

Run: `command -v ansible-lint >/dev/null && ansible-lint ansible/ || echo "ansible-lint not installed, skipping"`
Expected: clean (fix any flagged issues), or the skip message.

- [ ] **Step 10: Commit**

```bash
git add ansible/roles/attacker ansible/requirements.yaml
git commit -m "Add attacker role: kernel swap, desktop, clipboard, shared folder, persistence, toolset"
```

---

### Task 14: End-to-end build validation + README + docs

**Files:**
- Create: `README.md`
- Create: `docs/networking.md`
- Create: `docs/host-integration.md`
- Create: `docs/extending.md`

**Interfaces:**
- Consumes: the whole repo.
- Produces: a validated build and operator documentation.

- [ ] **Step 1: Full build (requires UTM, ~10+ min)**

```bash
cp lab.conf.example lab.conf
make preflight
make up
```
Expected: images fetched, VM created, SSH comes up, Ansible completes. Watch with `make up 2>&1 | tee build.log` and `make status` in another shell.

- [ ] **Step 2: Validate the flagged UTM features (Task 7 Step 3)**

```bash
make ssh kali
# in the guest:
lsblk                       # a second disk (data) of DATA_DISK_GB is present
ls -la /data                # mounted (persist_mode=data); ~/engagements -> /data
mountpoint -q ~/share && echo "share mounted" || echo "share not mounted (see host-integration.md)"
systemctl is-active spice-vdagentd
```
Fix `create-vm.applescript` / `integration.yaml` if the data disk or share is missing, then `make configure` (or rebuild) and re-check. Confirm the XFCE greeter renders in the UTM window and does not auto-log-in.

- [ ] **Step 3: Validate persistence round-trip**

```bash
make ssh kali
echo "loot" | sudo tee /data/proof.txt   # (persist_mode=data)
exit
make destroy         # type yes
make up
make ssh kali
cat /data/proof.txt  # must print "loot" — data survived the rebuild
```
Expected: `loot`. If the file is gone, the destroy-time copy-back or re-import failed — inspect `destroy.sh`'s `datadisk` query and the `persist/data.qcow2` timestamps; fall back to host-side persistence per the spec if unreliable.

- [ ] **Step 4: Validate bridged mode**

```bash
make down
sed -i '' 's/^NET_MODE=.*/NET_MODE="bridged"/' lab.conf   # macOS sed
make destroy && make up
make ssh kali        # reaches the box on its LAN IP
```
Expected: the box gets a LAN IP, SSH works. Reset `NET_MODE="nat"` afterward if that is your default.

- [ ] **Step 5: Write `README.md`**

Model it on `LAB/README.md`. Cover: what it is (single main Kali box, no lab targets, no anonymity), the three-phase architecture table, requirements (Apple Silicon, UTM, qemu, xorriso, ansible; ~40 GB disk with `default` toolset + desktop + data disk), quick start (`cp lab.conf.example lab.conf` → `make up` → `make ssh kali`), the `lab.conf` knobs (NET_MODE, KALI_TOOLSET, KALI_TOOL_GROUPS, ATTACKER_GUI, CLIPBOARD, PERSIST_MODE, DATA_DISK_GB, resources), the directory-lifecycle table (`images/` kept, `persist/` kept, `share/` user, `generated/` wiped), the make targets, and a Safety note (authorised use only; bridged puts the box on your real LAN). Link the three docs below.

- [ ] **Step 6: Write `docs/networking.md`**

Explain NAT vs bridged concretely: NAT = emulated SLIRP, `127.0.0.1:2201` SSH forward, portable; bridged = own DHCP LAN IP, LAN attacks + inbound callbacks, discovered via `utmctl ip-address`, needs DHCP and no client isolation. Note how `make ssh` resolves each, and the first-run UTM-key caveat.

- [ ] **Step 7: Write `docs/host-integration.md`**

Document: clipboard (SPICE, `CLIPBOARD`), the shared folder (`share/` ↔ `~/share`, the 9p/WebDAV validation outcome from Task 7), and persistence (`PERSIST_MODE` data vs home, what survives `make destroy`, the round-trip mechanism and its fallback). Record the confirmed UTM share mechanism here.

- [ ] **Step 8: Write `docs/extending.md`**

Document the v1 extension points from the spec: personal dotfiles/git identity (via `share/` or `PERSIST_MODE=home`), HTB/THM VPN (`openvpn` + a config dropped in `share/`), and growing `LAB_VMS` into a fleet (add an entry + reuse the role).

- [ ] **Step 9: Commit**

```bash
git add README.md docs/networking.md docs/host-integration.md docs/extending.md
git commit -m "Add README and operator docs; validate end-to-end build"
```

---

## Self-Review

**Spec coverage:**
- Single Kali box, no targets/segment/anonymity → Tasks 1–13 (scope enforced throughout). ✓
- 3-layer architecture (provision/bootstrap/config) → Tasks 5–13. ✓
- Selectable `NET_MODE` nat/bridged → lib `nic_mode` (T2), applescript (T7), create-vm (T8), up bridged discovery (T10), ssh (T11), networking doc (T14). ✓
- Toolset default + selectable + additive groups → `role_attacker.yaml` + `toolset.yaml` (T12–13). ✓
- Always-on XFCE, greeter, no auto-login, kernel swap → `console-kernel.yaml` + `desktop.yaml` (T13). ✓
- Console password, key-only SSH → cloud-init (T6) + `console-auth.yaml` (T13). ✓
- Clipboard, shared folder, persistent data disk, `PERSIST_MODE` data/home → `integration.yaml` (T13), create-vm data disk (T8), destroy round-trip (T9). ✓
- Higher defaults 6/8192/80, `DATA_DISK_GB=40` → `lab.conf.example` (T2). ✓
- Directory lifecycles (`images/`+`persist/` kept, `generated/` wiped) → `.gitignore` (T1), `destroy.sh` (T9). ✓
- make targets incl. `console`, no `verify` → Makefile (T3). ✓
- Tests: parse-vm-entry, nic-mode, persist-roundtrip → T2, T9. ✓
- Risks/first-run validation (data disk, bridged IP, share mechanism, UTM keys) → T7 Step 3, T14 Steps 2–4. ✓
- Extension points documented → `docs/extending.md` (T14). ✓

**Placeholder scan:** No `TBD`/`TODO`/"handle edge cases". The two genuinely UTM-version-dependent keys (`directory shares`, the 3rd-drive record) are real validation steps with concrete probe commands and a decision rule + documented fallback, not placeholders — consistent with how both sibling repos treat UTM-version-dependent behavior.

**Type/name consistency:** `nic_mode`, `ssh_port_for`, `data_disk_path`, `share_dir`, `persist_action` are defined in T2/T9 and used consistently in T8/T10/T11. `create-vm.sh` emits `<name> <ssh_port> <mode>` (T8) and `up.sh` reads exactly those three fields (T10). `gen-inventory.sh` consumes `<short> <name> <host> <port>` and `up.sh` emits exactly those (T10). Ansible vars (`attacker_toolset`, `attacker_gui`, `attacker_clipboard`, `attacker_password`, `persist_mode`, `kali_tool_groups`) are passed by `up.sh` (T10), defaulted in `role_attacker.yaml` (T12), and consumed in the role (T13) — names match.
