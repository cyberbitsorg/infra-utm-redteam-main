# infra-utm-redteam-main

A single-command, single Kali attack box on UTM for Apple
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
> controls UTM (a prompt, then System Settings > Privacy & Security >
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

## Commands

```bash
make help          # list all targets
make preflight     # check tools, generate the lab SSH key
make up            # full hands-off build: preflight, provision, configure
make provision     # create and boot the VM only, no Ansible
make configure     # run Ansible against the running VM
make status        # show VM status
make ssh kali      # SSH into the box
make console kali  # serial console (recovery path, any kernel)
make down          # stop the VM (keeps it)
make destroy       # stop and delete the VM; images/ and persist/ are kept
make lint          # syntax-check scripts and Ansible
make test          # run the shell unit tests
```

## Configuration

`lab.conf` is copied from `lab.conf.example` and gitignored, so nothing in it
(including `ATTACKER_PASSWORD`) ever lands in git. The knobs that matter day
to day:

| Setting | Values | Default | What it controls |
|---|---|---|---|
| `NET_MODE` | `nat` \| `bridged` | `nat` | `nat`: emulated SLIRP NIC, portable, host reaches the box via a `127.0.0.1` SSH forward. `bridged`: the box gets its own LAN IP. See Networking below |
| `KALI_TOOLSET` | `curated` \| `headless` \| `default` \| `large` | `default` | Which Kali metapackage to install (`kali-linux-default` is the standard installer set) |
| `ATTACKER_GUI` | `xfce` \| `none` | `xfce` | Whether the XFCE desktop + LightDM greeter is installed |
| `DISPLAY_RESOLUTION` | `<W>x<H>` \| `dynamic` | `1920x1080` | Pin the guest desktop to a resolution and let UTM scale it into its window, or let the guest follow the window. See The display below |
| `DESKTOP_COMPOSITING` | `yes` \| `no` | `no` | XFCE drop shadows, transparency and fades. Each is a full-screen CPU redraw here |
| `CLIPBOARD` | `yes` \| `no` | `yes` | SPICE clipboard sharing (`spice-vdagent`) between macOS and the guest desktop |
| `MULLVAD` | `yes` \| `no` | `no` | Mullvad VPN app and Mullvad Browser from Mullvad's apt repository. See Mullvad below |
| `KEEP_HOME` | `yes` \| `no` | `yes` | `yes`: the persistent disk is `/home`, so dotfiles, keys and tool state survive a rebuild. `no`: the disk is scratch at `/data` (`~/engagements` points at it) and every rebuild gives a clean home |
| `SHARED_DIR` | path | `~/Sandbox` | Host folder shared into the guest, mounted in the lab user's home under the same name |
| `DATA_DISK_GB` | integer | `40` | Size of the persistent disk at first creation; never shrunk |
| `VM_NAME` | string | `kali` | Short VM name; the UTM VM is `<LAB_PREFIX>-<VM_NAME>` |
| `VM_CPU` / `VM_RAM` / `VM_DISK_GB` | integer | `4` / `8192` / `80` | VM resources (cores / MiB / GB) |

See `lab.conf.example` for the full set (identity, image pin, etc.).

## Networking

The box has one NIC, whose mode is set by `NET_MODE` and passed straight to
`create-vm.applescript`.

`nat` maps to UTM's `emulated` mode (QEMU SLIRP). The guest gets outbound
internet, nothing reaches it except a `127.0.0.1` to guest `22` port forward on
`HOST_SSH_PORT=2400` (`scripts/lib.sh`), and it works on any network, including
Wi-Fi with client isolation or a captive portal. Port forwards only work on
`emulated`, which is why `nat` is not vmnet-backed.

`bridged` puts the guest on the physical LAN with its own DHCP address, so
ARP spoofing, LLMNR/NBNS poisoning and inbound callbacks behave like a real
host. There is no `127.0.0.1` forward here; the host connects to the LAN IP on
port `22`. That IP comes from `utmctl ip-address`, which needs the guest's
`qemu-guest-agent` reporting, and `make up` polls up to 3 minutes for it. If it
times out, the network probably isolates clients or blocks unknown DHCP
clients: switch back to `nat`, or get in with `make console kali`.

The port is deliberately clear of the sibling repos, which use 2200 plus index
(`infra-utm-redteam-lab`) and 2300 plus index (`infra-utm-anon-egress`), so all
three can be up at the same time.

`make ssh` follows the same split: `127.0.0.1:2400` for `nat`, or
`ansible_host` from `ansible/inventory/hosts.generated.yaml` for `bridged`,
falling back to a live `utmctl ip-address` query if that file is stale.

## Host integration

`CLIPBOARD=yes` installs `spice-vdagent` in the guest, which together with
UTM's SPICE display gives ordinary copy/paste with macOS. Verify with
`systemctl is-active spice-vdagentd`.

### The display

The box runs on UTM's `virtio-gpu-pci` display (`VM_DISPLAY` in
`scripts/lib.sh`), which has **no GPU acceleration**. That is not an oversight.
UTM's accelerated devices, `virtio-gpu-gl-pci` and `virtio-ramfb-gl`, both come
up black here: glamor initialises against virgl (ANGLE onto Metal) and Xorg
logs no error at all, LightDM's greeter starts and prompts for a password, yet
nothing reaches the framebuffer -- a capture of the root window taken inside the
guest comes back solid black even immediately after `xsetroot -solid red`.
Tested on UTM 4.7.5 / Apple silicon. If a later UTM fixes it, `VM_DISPLAY` is
the one line to change.

So Xorg refuses glamor (`Refusing to try glamor on llvmpipe`) and paints every
pixel on the CPU. That is survivable, but only if you keep the pixel count and
the repaint rate down, which is what the two `lab.conf` knobs are for. Left
unchecked, a Retina-sized framebuffer starves `virtio_gpu` until every atomic
commit hits its ten-second `flip_done timed out` and the desktop freezes for
minutes at a stretch:

- `DISPLAY_RESOLUTION=<W>x<H>` pins the guest and lets UTM scale the picture
  into its window, so dragging the window costs the guest nothing. Ansible
  writes the mode into `/etc/X11/xorg.conf.d/10-resolution.conf`, which covers
  the greeter as well as the session. `dynamic` instead lets the guest follow
  the window, which turns every resize step into a mode change -- the single
  most reliable way to lock the display up.
- `DESKTOP_COMPOSITING=no` turns off XFCE's shadows, transparency and fades,
  each of which is a full-screen redraw with no GPU behind it.

Both are reconciled onto an existing VM by `make up`, and a resolution change
restarts LightDM only when nobody is logged in. To check the state in the guest:

```sh
xrandr | grep '\*'               # the mode actually in use
sudo dmesg | grep -c flip_done   # want 0; anything above 0 means the display is stalling
```

### Sandbox: the shared folder

`SHARED_DIR` on the Mac (`~/Sandbox` by default) appears in the guest home
under the same name. Point it somewhere else in `lab.conf` and both sides
follow, since the guest folder is the basename of that path; a rename also
clears the old mount and `fstab` line on the next `make configure`. The name
cannot contain spaces, which `make preflight` rejects, because it becomes an
`fstab` entry. The folder lives outside the repo, so engagement files never sit
in a git working tree, and it survives `make destroy` untouched because it is
just a folder on the Mac. Use it for dotfiles, `.ovpn` configs and loot.

Linking it takes one manual step per VM, and it cannot be automated: UTM's QEMU
backend accepts a share path only from a file picker, never over AppleScript
(the path is stored as a sandbox bookmark that only macOS can mint). Everything
else is already wired up, so all you do is point UTM at the folder:

1. `make down` if the VM is running. UTM only edits settings on a stopped VM.
2. Open UTM, select `main-kali` in the sidebar, and click the sliders icon
   (Edit selected VM).
3. Pick `Sharing` in the settings list.
4. Leave `Directory Share Mode` on `VirtFS`. Provisioning already set it; if it
   reads `None`, set it to `VirtFS`.
5. Next to `Shared Directory`, click `Browse` and choose your `~/Sandbox`
   folder. Leave the read-only box unchecked so the guest can write back.
6. Click `Save`, then `make up` to boot the VM again.
7. `make configure` mounts it, or run `sudo mount -a` in the guest.

Check it landed:

```bash
make ssh kali
mountpoint -q ~/Sandbox && echo mounted || echo "not mounted"
```

The 9p mount tag is always `share`, whatever the folders are named on either
side, so [integration.yaml](ansible/roles/attacker/tasks/integration.yaml)
mounts `src: share`. That mount is `nofail`: skip the steps above and you get an
empty `~/Sandbox`, not a broken build.

On write access: UTM shares with `security_model=mapped-xattr`, so the guest's
idea of ownership lives in `user.virtfs.*` xattrs on the host file. Anything
created on the Mac carries no such xattr and falls back to the raw macOS uid,
which is a stranger to the guest, so a plain 9p mount would be read-only for
everything you put there from macOS.

Provisioning avoids that entirely. The 9p share is mounted privately at
`/mnt/shared` (root only), and `bindfs` re-presents it at `~/Sandbox` with
every file forced to the lab user. The whole tree is writable from the guest no
matter which side created it, with nothing to chown by hand, and ownership on
the Mac is never touched. Both mounts are in the guest's `fstab` with `nofail`,
so they come back on every boot and an unconfigured share still leaves an empty
`~/Sandbox` rather than a broken build.

### Persistence

The persistent disk (`persist/data.qcow2`, `DATA_DISK_GB`) is formatted ext4 on
first use only and survives `make destroy`. `KEEP_HOME` decides what it is for.

With `KEEP_HOME=yes` the disk becomes `/home`, so dotfiles, SSH keys, shell
history and tool state all survive a rebuild. Before mounting it the first
time, provisioning copies the current `/home` onto the disk and refuses to
mount unless the lab user's `.ssh` is on it. Without that, a bare disk would
bury `authorized_keys` and lock you out on the next connection.

With `KEEP_HOME=no` the disk is scratch space at `/data`, `~/engagements`
points at it, and every rebuild gives you a clean home.

Going from `no` to `yes` happens on the next `make configure`, carrying your
current home across. The other direction cannot be done on a running box, since
it means pulling `/home` out from under every running process, so provisioning
stops with an explanation instead: rebuild with `make destroy` then `make up`.

## Mullvad

`MULLVAD=yes` installs the Mullvad VPN app and Mullvad Browser
([mullvad.yaml](ansible/roles/attacker/tasks/mullvad.yaml)). Kali packages
neither, and the `.deb` downloads from Mullvad's site carry no upgrade path, so
provisioning adds Mullvad's own apt repository (signed by
`/usr/share/keyrings/mullvad-keyring.asc`) and both then move with the box's
normal `apt upgrade`. The suite is pinned to `stable` rather than taken from
`lsb_release -cs` the way Mullvad's instructions do, because on Kali that
answers `kali-rolling`, which is not a suite the repository has — apt would
fail on every update from then on.

The browser only follows when `ATTACKER_GUI` is a desktop, since it has no
headless use. The VPN is installed either way: without a desktop the `mullvad`
CLI drives the same daemon.

**On ARM64 the browser is the alpha channel.** Mullvad Browser comes from Tor
Browser, which has no stable Linux `aarch64` release, so Mullvad's repository
carries stable `mullvad-browser` for `amd64` only and `mullvad-browser-alpha`
for `arm64`. On this box the role picks the alpha package and says so during the
run. The VPN app itself is a normal stable `arm64` build.

Nothing is logged in for you:

```bash
make ssh kali
mullvad account login <account number>
mullvad connect && mullvad status
```

Setting `MULLVAD=no` and running `make configure` is a real removal, not a skip:
both packages are purged and the repository and key are taken back out. Purging
`mullvad-vpn` drops `/etc/mullvad-vpn`, so the logged-in account goes with it.

`make configure` is the normal way to apply a flip. To run just these tasks,
note that a direct playbook call does not read `lab.conf`, so the value has to
come along:

```bash
ansible-playbook ansible/playbook.yaml --tags mullvad -e attacker_mullvad=true
```

## Directory layout

| Directory | Holds | Lifecycle |
|---|---|---|
| `images/` | The verified ARM64 Kali base image + checksums | Fetched once; kept by `make destroy` |
| `persist/` | The persistent data disk (`data.qcow2`) | Kept by `make destroy`; re-attached on the next `make up` |
| `SHARED_DIR` (`~/Sandbox`, outside the repo) | Host-side shared folder, live-mounted into the guest at `~/Sandbox` | User-managed; not touched by the tooling |
| `generated/` | Per-build OS staging disk + cloud-init seed ISO | Rebuilt every `make up`; wiped by `make destroy` |

Also gitignored: `lab.conf` and `ansible/inventory/hosts.generated.yaml`.

## Safety

This box ships the full offensive Kali toolset with no isolation of its own.

- Use it only against systems you own or are explicitly authorised to test.
- `NET_MODE=bridged` puts the box directly on your real LAN with its own DHCP
  address, so LAN-facing tools (ARP spoofing, LLMNR/NBNS poisoning, inbound
  callback listeners) now reach every device on that network, not a sandbox.
  Prefer `nat` unless you specifically need a LAN-facing attacker.
- The console/GUI password (`ATTACKER_PASSWORD`) only guards local logins; SSH
  is always key-only.

## Validate on first run

Provisioning drives UTM's AppleScript interface, so two things depend on the
UTM version installed and are worth confirming on the first `make up`:

- The directory share, since VirtFS is set from `create-vm.applescript` but the
  host folder is picked in UTM's settings. Until it works, move files with
  `scp` over the SSH port.
- The data-disk round-trip. UTM imports `persist/data.qcow2` into its own VM
  bundle, so `make destroy` copies the live disk back out before deleting the
  VM, and the next `make up` re-attaches it. Test it with
  `echo loot | sudo tee /data/proof.txt`, then `make destroy && make up`, and
  check the file is still there. If it is not, keep loot in `~/Sandbox` instead.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
