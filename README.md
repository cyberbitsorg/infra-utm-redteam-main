# infra-utm-redteam-main

A single-command, reproducible main Kali attack box on UTM for Apple
Silicon. This is a daily-driver box: a full desktop, the standard Kali
toolset, host clipboard/file integration, and a persistent data disk that
survives a full teardown and rebuild.

## Architecture

Three layers provision the box, mirroring the pattern used across these
infra repos:

| Layer | Tool | What it does | When it runs |
|-------|------|---------------|---------------|
| Provisioning | `scripts/*` + `create-vm.applescript` | Creates the Kali VM from the verified ARM64 cloud image, attaches the NIC per `NET_MODE`, the persistent data disk, and the host shared folder; boots it | `make up` |
| Bootstrap | `cloud-init/kali.user-data.yaml` | Creates the lab user, injects the SSH key, grows the rootfs, installs Python + qemu-guest-agent | First boot only |
| Configuration | `ansible/` (role `attacker`) | Installs the Kali toolset, swaps in the standard kernel, sets up the XFCE desktop + greeter, sets the console password, mounts the shared folder and data disk | Automatic after boot, and on every `make configure` |

See [`docs/superpowers/specs/2026-08-04-utm-redteam-main-design.md`](docs/superpowers/specs/2026-08-04-utm-redteam-main-design.md)
for the full design rationale behind these choices.

## Requirements

- Apple Silicon Mac (ARM64). The base image is `aarch64`, so it will not
  boot on Intel
- [UTM](https://mac.getutm.app/): `brew install --cask utm` or download the
  app and drop it in `/Applications`. The scripts only need `UTM.app` present;
  `utmctl` is invoked from inside the app bundle
- `qemu` for `qemu-img` (disk staging/resize): `brew install qemu`
- An ISO builder for the cloud-init seed: `xorriso` (`brew install xorriso`)
  or the built-in macOS `hdiutil`, used automatically if `xorriso` is absent
- `ansible`: `brew install ansible`
- Free disk space: plan for ~40 GB or more. The base image download is a
  few GB; the OS disk defaults to `VM_DISK_GB=80` and the persistent data
  disk to `DATA_DISK_GB=40`, but both are thin-provisioned (qcow2/raw), so
  actual usage starts well below that and grows with what you install and
  save. The default `KALI_TOOLSET=default` plus the always-on XFCE desktop is
  the bulk of the OS disk's real usage.

`make preflight` checks all of the above and generates an SSH key if you
don't already have one at `LAB_SSH_KEY`.

> First run: macOS will ask permission the first time your terminal
> controls UTM (a prompt, then System Settings → Privacy & Security →
> Automation). Approve it, or provisioning cannot create the VM.

## Quick start

```bash
cp lab.conf.example lab.conf
make up
make ssh kali
```

`make up` runs preflight, downloads and verifies the ARM64 Kali cloud image,
creates and boots the VM, waits for SSH, then applies Ansible. Allow several
minutes on first run for the image download and toolset install.

## Configuration

`lab.conf` is copied from `lab.conf.example` and gitignored, so nothing in it
(including `ATTACKER_PASSWORD`) ever lands in git. The knobs that matter day
to day:

| Setting | Values | Default | What it controls |
|---|---|---|---|
| `NET_MODE` | `nat` \| `bridged` | `nat` | `nat`: emulated SLIRP NIC, portable, host reaches the box via a `127.0.0.1` SSH forward. `bridged`: the box gets its own LAN IP; see `docs/networking.md` |
| `KALI_TOOLSET` | `curated` \| `headless` \| `default` \| `large` | `default` | Which Kali metapackage to install (`kali-linux-default` is the standard installer set) |
| `ATTACKER_GUI` | `xfce` \| `none` | `xfce` | Whether the XFCE desktop + LightDM greeter is installed |
| `CLIPBOARD` | `yes` \| `no` | `yes` | SPICE clipboard sharing (`spice-vdagent`) between macOS and the guest desktop |
| `PERSIST_MODE` | `data` \| `home` | `data` | `data`: persistent disk mounted at `/data` (`~/engagements` symlinked to it), home is clean on every rebuild. `home`: the persistent disk is `/home`, so dotfiles/keys/tool state survive rebuilds too |
| `DATA_DISK_GB` | integer | `40` | Size of the persistent disk at first creation; never shrunk |
| `VM_NAME` | string | `kali` | Short VM name; the UTM VM is `<LAB_PREFIX>-<VM_NAME>` |
| `VM_CPU` / `VM_RAM` / `VM_DISK_GB` | integer | `4` / `8192` / `80` | VM resources (cores / MiB / GB) |

See `lab.conf.example` for the full set (identity, image pin, etc.). This repo
builds exactly one box; `docs/extending.md` covers dotfiles, VPN configs, and
where the sibling `infra-utm-redteam-lab` fits if you need several machines.

## Directory layout

| Directory | Holds | Lifecycle |
|---|---|---|
| `images/` | The verified ARM64 Kali base image + checksums | Fetched once; kept by `make destroy` |
| `persist/` | The persistent data disk (`data.qcow2`) | Kept by `make destroy`; re-attached on the next `make up` |
| `share/` | Host-side shared folder, live-mounted into the guest at `~/share` | User-managed; not touched by the tooling |
| `generated/` | Per-build OS staging disk + cloud-init seed ISO | Rebuilt every `make up`; wiped by `make destroy` |

Also gitignored: `lab.conf` and `ansible/inventory/hosts.generated.yaml`.

## Make targets

```bash
make help        # list all targets
make preflight    # check tools, generate the lab SSH key
make up           # full hands-off build: preflight, provision, configure
make provision    # create and boot the VM only, no Ansible
make configure    # run Ansible against the running VM
make status       # show VM status
make ssh kali      # SSH into the box
make console kali   # serial console (recovery path, any kernel)
make down         # stop the VM (keeps it)
make destroy      # stop and delete the VM; images/ and persist/ are kept
make lint         # syntax-check scripts and Ansible
make test         # run the shell unit tests
```

## Safety

This box ships the full offensive Kali toolset with no isolation of its own.

- Use it only against systems you own or are explicitly authorised to test.
- `NET_MODE=bridged` puts the box directly on your real LAN with its own DHCP
  address, so LAN-facing tools (ARP spoofing, LLMNR/NBNS poisoning, inbound
  callback listeners) now reach every device on that network, not a sandbox.
  Prefer `nat` unless you specifically need a LAN-facing attacker.
- The console/GUI password (`ATTACKER_PASSWORD`) only guards local logins; SSH
  is always key-only.

## Documentation

- [`docs/networking.md`](docs/networking.md): NAT vs bridged, how `make ssh`
  resolves each, DHCP/isolation caveats
- [`docs/host-integration.md`](docs/host-integration.md): clipboard, shared
  folder, and data-disk persistence in detail
- [`docs/extending.md`](docs/extending.md): dotfiles/git identity, HTB/THM
  VPN, and multi-VM notes

## Validate on first run

Because provisioning talks to UTM's AppleScript interface, two things depend
on the exact UTM version installed and are worth confirming on your first
`make up` (see `docs/host-integration.md` for detail on both):

- The directory-share mechanism: whether UTM mounts `share/` into the
  guest as 9p or SPICE WebDAV on your UTM version.
- The data-disk destroy round-trip: that `make destroy` correctly copies
  the live data disk back out to `persist/data.qcow2` before deleting the VM,
  so `make up` afterward restores it intact.

If either behaves unexpectedly, the fallback for both is documented in
`docs/host-integration.md`.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
