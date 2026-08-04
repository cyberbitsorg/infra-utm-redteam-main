# infra-utm-redteam-main — design

A single-command, reproducible **main Kali attack box** on UTM for Apple Silicon.
This is the operator's daily-driver box: full desktop, full toolset, host
integration, and persistent work data. It is a sibling to two existing repos and
reuses their machinery:

- `../infra-utm-redteam-lab` — a multi-VM lab (Kali attacker + vulnerable
  targets on an isolated segment). Source of the `attacker` role, the
  standard-kernel/UTM-console swap, and the whole `scripts/` + cloud-init +
  Ansible pattern.
- `../infra-utm-anon-egress` — a Kali workstation behind a WireGuard/nftables
  anonymity gateway. Source of the per-role selectable NIC layout, the serial
  `console.sh`, and the SPICE clipboard/desktop touches.

This repo takes the useful parts of both and **deliberately drops**: the
vulnerable targets and the isolated `10.10.10.0/24` lab segment; and the entire
anonymity stack (gateway VM, WireGuard, Mullvad, nftables kill-switch,
`verify.sh`, `unbound`). There is exactly **one VM** and no gateway.

## Goals

- One command (`make up`) builds a ready-to-work Kali box, hands-off.
- Reproducible and re-runnable: Ansible is idempotent; a rebuild is identical.
- A real daily driver, not a throwaway: full desktop always on, standard Kali
  toolset, clipboard + shared folder + a persistent data disk whose contents
  survive a full `make destroy` + rebuild.
- Flexible networking: NAT (portable) or bridged (first-class LAN host),
  selectable per build.

## Non-goals

- No anonymity/egress control (that is `infra-utm-anon-egress`).
- No vulnerable targets or lab network (that is `infra-utm-redteam-lab`).
- No multi-VM fleet in v1 (the config keeps the fleet array so it can grow, but
  the shipped build is a single machine).
- No baked-in personal identity in v1 (dotfiles, git identity, HTB/THM VPN) —
  documented as extension points, not built.

## Architecture

Three provisioning layers plus use, mirroring the sibling repos:

| Layer | Tool | What it does | When |
|-------|------|--------------|------|
| Provisioning | `scripts/*` + `create-vm.applescript` | Create one Kali VM from the verified ARM64 image, attach NICs per `NET_MODE`, attach the persistent data disk + shared folder, boot | `make up` |
| Bootstrap | `cloud-init/kali.user-data.yaml` | Create the user, inject the SSH key, grow rootfs, install python + qemu-guest-agent, prepare `/data` | first boot only |
| Configuration | `ansible/` (role `attacker`) | Toolset, standard-kernel swap, XFCE desktop + greeter, console password, msfdb, SPICE agent, shared-folder and data-disk mounts | after boot, and on every `make configure` |
| Use | `make ssh` / `make console` / UTM window | Work on the box | on demand |

`create-vm.applescript` (with `vm-config.applescript`) is the single integration
point with UTM; UTM property keys live only there.

### Ansible layout

One host, one role. The role is split into focused task files rather than the
lab's multi-role playbook:

```
ansible/
  playbook.yaml            # one play: hosts: all, role: attacker
  ansible.cfg              # (repo root) reused from siblings
  group_vars/
    all.yaml               # timezone, common_packages
    role_attacker.yaml     # toolset selection, gui, password, persist/clipboard flags
  inventory/
    hosts.generated.yaml   # written by gen-inventory.sh (gitignored)
  roles/
    common/tasks/main.yaml # timezone, common packages, MOTD
    attacker/
      tasks/
        main.yaml          # orchestration: include the files below in order
        toolset.yaml       # Kali metapackage/groups + msfdb
        console-kernel.yaml# standard kernel swap + grub pin + reboot; remove agetty autologin
        desktop.yaml       # kali-desktop-xfce + LightDM greeter (no autologin)
        console-auth.yaml  # console/GUI password (chpasswd on guest)
        integration.yaml   # spice-vdagent, shared folder mount, /data or /home mount
      handlers/main.yaml
```

## Component: networking (`NET_MODE`)

Selectable in `lab.conf`, passed to `create-vm.applescript` as an argument (same
technique anon-egress uses for its per-role NIC layouts).

- **`nat`** (default, recommended): one `emulated` (QEMU user/SLIRP) NIC —
  internet, visibility of the host LAN, and a `127.0.0.1:<port>` SSH
  port-forward. The hostfwd works only on `emulated` (UTM `shared`/vmnet modes
  silently ignore port forwards). Portable; works on any Wi-Fi including
  captive-portal networks. This is exactly the redteam-lab NAT NIC.
- **`bridged`**: one `bridged` (vmnet-bridged) NIC — the box gets its own DHCP
  address on the physical LAN and behaves as a first-class host (LLMNR/NBNS
  poisoning, ARP spoofing, inbound reverse-shell callbacks, direct SSH to its
  LAN IP). There is **no** `127.0.0.1` port-forward in this mode (hostfwd needs
  SLIRP), so the host reaches the box by its discovered LAN IP.

`scripts/lib.sh` gains `nic_mode()` (reads `NET_MODE`, default `nat`, rejects
anything else) and the SSH-target resolution branches on it:

- NAT: target is `127.0.0.1` port `SSH_PORT_BASE + index` (as today).
- bridged: target is the guest's LAN IP, discovered via
  `utmctl ip-address <vm>` (qemu-guest-agent, installed by cloud-init), on
  port 22.

`gen-inventory.sh` writes `ansible_host`/`ansible_port` accordingly, so Ansible,
`make ssh`, and `make status` all work in both modes with no per-mode flags.

## Component: toolset (`KALI_TOOLSET` + `KALI_TOOL_GROUPS`)

`role_attacker.yaml` selects the package set from `KALI_TOOLSET`
(passed in by `up.sh` as `-e attacker_toolset=`), default **`default`**:

| Value | Installs |
|-------|----------|
| `curated` | small headless subset (nmap, netcat, gobuster, ffuf, hydra, sqlmap, metasploit-framework, seclists) |
| `headless` | `kali-linux-headless` |
| `default` (default) | `kali-linux-default` — the standard installer toolset |
| `large` | `kali-linux-large` |

`KALI_TOOL_GROUPS` (space/comma separated, without the `kali-tools-` prefix) is
**additive** on top of the selected toolset — extra function groups (`web`,
`passwords`, `top10`, …). Empty by default. Unlike anon-egress, there is no VPN
watch-list/purge here: this box has no anonymity invariant, so `kali-linux-*`
umbrellas and any tool group are all allowed.

`msfdb init` + PostgreSQL enabled so Metasploit is usable on first boot (guarded
on the `msfdb` binary, so stripping metasploit from the toolset does not break
the play).

## Component: desktop (always on)

XFCE is always installed (`ATTACKER_GUI` defaults to `xfce`; `none` is possible
but off the happy path). Because Kali's genericcloud kernel has no virtio-gpu/DRM
driver, the console-kernel task installs `linux-image-arm64` and pins it with
`GRUB_DEFAULT=saved` (reading the real menuentry ids out of `grub.cfg`, keeping
the cloud kernel as a fallback — never purged), then reboots into it. The desktop
task then installs `kali-desktop-xfce` + LightDM, with a greeter that prompts for
`ATTACKER_PASSWORD` and **never auto-logs-in**. Kali's agetty root-autologin
drop-ins (tty1 + serial) are removed. SSH stays key-only regardless.

Ordering (from anon-egress's hard-won lessons): flush the kernel-reboot handler
before the desktop include (a greeter needs the framebuffer of the running
standard kernel), and write any LightDM/`no-autologin` drop-in before the package
that ships the default.

## Component: host integration & persistence

Three features, all safe here because there is no anonymity invariant to protect:

1. **Clipboard** (`CLIPBOARD`, default `yes`): `spice-vdagent` installed and
   `spice-vdagentd` enabled → copy/paste between macOS and the Kali desktop.

2. **Shared folder**: a repo-side `share/` directory mounted live into the guest
   at `~/share` for two-way file transfer (payloads in, loot out). Lives on the
   Mac, so it survives every teardown. Implemented via UTM's SPICE WebDAV /
   virtio-fs share configured in `create-vm.applescript`; the guest mount is set
   up in `integration.yaml`. (The exact UTM share mechanism is a first-run
   validation item — see Risks.)

3. **Persistent data disk** (`DATA_DISK_GB`, default 40; `PERSIST_MODE`):
   a second qcow2 kept in `persist/` — **outside** the disposable OS lifecycle.
   - `PERSIST_MODE=data` (default): mounted at `/data`, with `~/engagements →
     /data`. The OS disk (and therefore `/home`, dotfiles, tool state) is clean
     on every rebuild; only `/data` persists.
   - `PERSIST_MODE=home`: the persistent disk holds `/home`, so dotfiles, SSH
     keys, and tool state survive a rebuild too (at the cost of not getting a
     clean home on rebuild).
   - `make destroy` preserves `persist/` and `images/` (exactly as the siblings
     preserve `images/`); the next `make up` re-attaches the same data disk, so a
     rebuild gives a fresh OS with your work intact.

### Directory layout & lifecycles

| Directory | Holds | Lifecycle |
|-----------|-------|-----------|
| `images/` | verified ARM64 Kali base image + checksum | fetched once; **kept** by `make destroy` |
| `persist/` | the persistent data disk (`data.qcow2`) | **kept** by `make destroy`; re-attached on `make up` |
| `share/` | host-side shared folder, live-mounted into the guest | user-managed; not touched by the tooling |
| `generated/` | per-build OS staging disk + cloud-init seed ISO | rebuilt every `make up`; **wiped** by `make destroy` |

Also gitignored: `lab.conf`, `ansible/inventory/hosts.generated.yaml`.

## Component: config surface (`lab.conf`)

```
LAB_PREFIX="redteam"                 # UTM VM name = <prefix>-<name>
LAB_USER="redteam"                   # guest user; Ansible connects as this
LAB_SSH_KEY="${HOME}/.ssh/id_ed25519_redteam.pub"

NET_MODE="nat"                       # nat | bridged
ATTACKER_PASSWORD="redteam"          # console/GUI password (SSH stays key-only)
ATTACKER_GUI="xfce"                  # xfce | none
CLIPBOARD="yes"                      # spice-vdagent clipboard sharing

KALI_TOOLSET="default"               # curated | headless | default | large
KALI_TOOL_GROUPS=""                  # extra kali-tools-* groups, additive

PERSIST_MODE="data"                  # data (/data) | home (/home)
DATA_DISK_GB=40                      # size of persist/data.qcow2 at first creation

LAB_CPU=6                            # daily-driver defaults
LAB_RAM=8192
LAB_DISK_GB=80

KALI_VERSION="2026.2"                # image pin; URLs derived as in siblings
# KALI_IMG_URL / KALI_SHA_URL / KALI_IMG_FILE

LAB_VMS=( "kali:attacker" )          # single machine; array kept for future growth
```

Secrets note: `lab.conf` is gitignored, so `ATTACKER_PASSWORD` never lands in
git (same posture as redteam-lab; anon-egress's separate `.env` is not needed
without per-VM secrets).

## Component: make targets & scripts

Targets (same verbs as the siblings, minus `verify`):

```
make help preflight up provision configure status ssh console down destroy lint test
```

Reused (adapted from the siblings): `lib.sh`, `up.sh`, `make-seed.sh`,
`fetch-images.sh`, `gen-inventory.sh`, `ssh.sh`, `status.sh`, `down.sh`,
`preflight.sh`, `wait-ssh.sh`, `console.sh` (from anon-egress), `Makefile`,
`ansible.cfg`, `vm-config.applescript`.

New or materially changed:
- `create-vm.applescript` — `NET_MODE` NIC selection; attach the persistent data
  disk and the shared folder.
- `create-vm.sh` / `destroy.sh` — persistent-disk create/attach and the
  destroy-time round-trip (see Risks).
- `lib.sh` — `nic_mode()`, bridged SSH-target discovery via `utmctl ip-address`.
- `cloud-init/kali.user-data.yaml` — single Kali bootstrap.
- `ansible/` — single `attacker` role, split task files.
- `lab.conf.example`, `README.md`, `docs/`.

## Testing

Keep the siblings' shell unit tests and add coverage for the new logic. Tests
run without UTM:

- `tests/parse-vm-entry.sh` — fleet-entry parser (reused).
- `tests/nic-mode.sh` — `NET_MODE` validation (nat/bridged accepted, junk
  rejected, default is nat) and the SSH-target branch per mode.
- `tests/persist-roundtrip.sh` — the destroy→preserve→re-attach logic for the
  data disk decides correctly whether to create vs. reuse `persist/data.qcow2`.

`make lint` = `bash -n` on scripts + `ansible-lint` if present (reused).

## Risks / first-run validation

Consistent with the siblings, a few UTM-version-dependent items are called out to
confirm on the first build:

1. **Persistent disk surviving `make destroy`.** UTM copies drive `source:`
   files into its own VM bundle at creation, so a naive attach dies with the
   bundle. Mitigation: `destroy.sh` stops the VM, copies the bundle's data-disk
   back out to `persist/data.qcow2`, then deletes the VM; `up.sh` re-imports it.
   The copy-back must be verified before the bundle delete, and this whole path
   is the primary first-run validation item. Fallback if the round-trip proves
   unreliable: keep persistence host-side only (shared folder), and treat the
   data disk as OS-lifecycle-bound.
2. **Bridged IP discovery.** `utmctl ip-address` depends on qemu-guest-agent
   being up; `wait-ssh.sh` must poll for the address in bridged mode before
   Ansible runs. Bridged also fails on networks without DHCP / with client
   isolation — documented, with `nat` as the always-works default.
3. **Shared-folder mechanism.** SPICE WebDAV vs. virtio-fs differs by UTM
   version and guest support; confirm which mounts cleanly on the target UTM and
   pin it in `create-vm.applescript` + the guest mount task.
4. **UTM AppleScript property keys.** As in both siblings, if a UTM version
   rejects a key in `create-vm.applescript`, adjust it there only.

## Extension points (documented, not built in v1)

- Personal identity: dotfiles, git identity, shell config — via the shared
  folder or `PERSIST_MODE=home`.
- HTB/THM VPN: `openvpn` + a config dropped in `share/`.
- Growing into a fleet: the `LAB_VMS` array and role machinery already support
  adding VMs and roles.
