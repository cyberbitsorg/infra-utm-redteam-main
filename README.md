# Kali VM on Apple Silicon

A single-command Kali attack box on UTM for Apple Silicon. This is a
daily driver box: a full desktop, the standard Kali toolset, host
clipboard and file integration, and a persistent data disk that survives
a full teardown and rebuild.

## Architecture

| Layer | Tool | What it does | When it runs |
|-------|------|---------------|---------------|
| Provisioning | `scripts/*` + `create-vm.applescript` | Creates the VM from the verified ARM64 cloud image, attaches the NIC, the persistent data disk and the host shared folder; boots it | `make up` |
| Bootstrap | `cloud-init/kali.user-data.yaml` | Creates the lab user, injects the SSH key, grows the rootfs, installs Python + qemu-guest-agent | First boot only |
| Configuration | `ansible/` (role `attacker`) | Kali toolset, standard kernel, XFCE desktop + greeter, console password, shared folder and data disk | After boot, and on every `make configure` |

## Requirements

- Apple Silicon Mac. The base image is `aarch64` and will not boot on Intel
- [UTM](https://mac.getutm.app/): `brew install --cask utm`. Only `UTM.app`
  needs to be present; `utmctl` is invoked from inside the app bundle
- `brew install qemu ansible` (`qemu-img` for disk staging and resize)
- An ISO builder for the cloud-init seed: `brew install xorriso`, or the
  built-in `hdiutil`, used automatically if `xorriso` is absent
- ~40 GB free. `VM_DISK_GB=80` and `DATA_DISK_GB=40` are both thin-provisioned,
  so real usage starts far below that and grows with what you install

`make preflight` checks all of it and generates an SSH key if `LAB_SSH_KEY`
does not exist yet.

> First run: macOS asks permission the first time your terminal controls UTM
> (a prompt, then System Settings > Privacy & Security > Automation). Approve
> it, or provisioning cannot create the VM.

## Quick start

```bash
cp lab.conf.example lab.conf
make up
make ssh kali
```

`make up` runs preflight, downloads and verifies the image, creates and boots
the VM, waits for SSH, then applies Ansible. Allow several minutes on the first
run for the download and the toolset install.

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
(including `ATTACKER_PASSWORD`) ever lands in git.

| Setting | Values | Default | What it controls |
|---|---|---|---|
| `KALI_TOOLSET` | `curated` \| `headless` \| `default` \| `large` | `default` | Which Kali metapackage to install |
| `ATTACKER_GUI` | `xfce` \| `none` | `xfce` | Whether the XFCE desktop + LightDM greeter is installed |
| `DISPLAY_RESOLUTION` | `<W>x<H>` \| `dynamic` | `1920x1080` | Pin the guest and let UTM scale, or let the guest follow the window. See The display |
| `DESKTOP_COMPOSITING` | `yes` \| `no` | `no` | XFCE shadows, transparency and fades. Each is a full-screen CPU redraw here |
| `CLIPBOARD` | `yes` \| `no` | `yes` | SPICE clipboard sharing with macOS |
| `MULLVAD` | `yes` \| `no` | `no` | Mullvad VPN app and Mullvad Browser. See Mullvad |
| `KEEP_HOME` | `yes` \| `no` | `yes` | `yes`: the persistent disk is `/home`. `no`: scratch at `/data`, with `~/engagements` pointing at it |
| `SHARED_DIR` | path | `~/Sandbox` | Host folder shared into the guest under the same name |
| `DATA_DISK_GB` | integer | `40` | Size of the persistent disk at first creation; never shrunk |
| `VM_NAME` | string | `kali` | The UTM VM is `<LAB_PREFIX>-<VM_NAME>` |
| `VM_CPU` / `VM_RAM` / `VM_DISK_GB` | integer | `4` / `8192` / `80` | Cores / MiB / GB |

See `lab.conf.example` for the full set (identity, image pin, etc.).

## Networking

The box has one NIC, in UTM's `emulated` mode (QEMU SLIRP). The guest gets
outbound internet and nothing reaches it except a `127.0.0.1` forward to guest
`22` on `HOST_SSH_PORT=2400`, so it works on any network, including wifi with
client isolation. Port forwards only work on `emulated`, which is why the NIC is
not vmnet-backed. The port is clear of the sibling repos (2200+index for
`infra-utm-redteam-lab`, 2300+index for `infra-utm-anon-egress`), so all three
can be up at once.

`make ssh` connects to `127.0.0.1:2400`.

## Host integration

`CLIPBOARD=yes` installs `spice-vdagent`, which together with UTM's SPICE
display gives ordinary copy/paste with macOS. Verify with
`systemctl is-active spice-vdagentd`.

### The display

Unfortunately, I had to pin the resolution in `lab.conf` (the resolution is
configurable though).

The box runs on UTM's `virtio-gpu-pci` display (`VM_DISPLAY` in
`scripts/lib.sh`), which has no GPU acceleration. That is not an oversight.
Both accelerated devices, `virtio-gpu-gl-pci` and `virtio-ramfb-gl`, come up
black here: glamor initialises against virgl, Xorg logs no error at all and
LightDM prompts for a password, yet nothing reaches the framebuffer; an
in-guest capture of the root window comes back solid black even right after
`xsetroot -solid red`. Tested on UTM 4.7.5. If a later UTM fixes it,
`VM_DISPLAY` is the one line to change.

So Xorg refuses glamor (`Refusing to try glamor on llvmpipe`) and paints every
pixel on the CPU. That is survivable, but only if you keep the pixel count and
the repaint rate down, which is what the two `lab.conf` knobs are for. Left
unchecked, a Retina-sized framebuffer starves `virtio_gpu` until every atomic
commit hits its ten-second `flip_done timed out` and the desktop freezes for
minutes at a stretch.

- `DISPLAY_RESOLUTION=<W>x<H>` pins the guest and lets UTM scale into its
  window, so dragging the window costs the guest nothing. Ansible writes the
  mode into `/etc/X11/xorg.conf.d/10-resolution.conf`, which covers the greeter
  as well as the session. `dynamic` instead turns every resize step into a mode
  change -- the single most reliable way to lock the display up.
- `DESKTOP_COMPOSITING=no` turns off XFCE's shadows, transparency and fades.

Both are reconciled onto an existing VM by `make up`, and a resolution change
restarts LightDM only when nobody is logged in. To check the state in the
guest:

```sh
xrandr | grep '\*'               # the mode actually in use
sudo dmesg | grep -c flip_done   # want 0; above 0 means the display is stalling
```

### Shared folder

`SHARED_DIR` on the Mac (`~/Sandbox` by default) appears in the guest home
under the same name. Point it somewhere else in `lab.conf` and both sides
follow; a rename also clears the old mount and `fstab` line on the next
`make configure`. The name cannot contain spaces, which `make preflight`
rejects, because it becomes an `fstab` entry. The folder lives outside the repo
and survives `make destroy` untouched, since it is just a folder on the Mac.
Use it for dotfiles, `.ovpn` configs, loot, etc.

Linking it takes one manual step per VM and cannot be automated: UTM's QEMU
backend accepts a share path only from a file picker, never over AppleScript
(the path is a sandbox bookmark that only macOS can mint). Everything else is
already wired up:

1. `make down` if the VM is running. UTM only edits settings on a stopped VM.
2. Open UTM, select `redteam-kali` in the sidebar, and click the sliders icon.
3. Pick `Sharing`, and leave `Directory Share Mode` on `VirtFS` (provisioning
   already set it; if it reads `None`, set it back).
4. Next to `Shared Directory`, click `Browse` and choose your `~/Sandbox`
   folder. Leave the read-only box unchecked.
5. `Save`, then `make up`, then `make configure` to mount it.

The 9p mount tag is always `share`, whatever the folders are named on either
side, so [integration.yaml](ansible/roles/attacker/tasks/integration.yaml)
mounts `src: share`. That mount is `nofail`: skip the steps above and you get
an empty `~/Sandbox`, not a broken build.

On write access, UTM shares with `security_model=mapped-xattr`, so the guest's
idea of ownership lives in `user.virtfs.*` xattrs on the host file. Anything
created on the Mac carries no such xattr and falls back to the raw macOS uid,
which is a stranger to the guest, so a plain 9p mount would be read-only for
everything you put there from macOS. Provisioning avoids that: the 9p share is
mounted privately at `/mnt/shared` (root only), and `bindfs` re-presents it at
`~/Sandbox` with every file forced to the lab user. The whole tree is writable
from the guest whichever side created a file, and ownership on the Mac is never
touched.

### Persistence

The persistent disk (`persist/data.qcow2`, `DATA_DISK_GB`) is formatted ext4 on
first use only and survives `make destroy`. `KEEP_HOME` decides what it is for.

With `KEEP_HOME=yes` the disk becomes `/home`, so dotfiles, SSH keys, shell
history and tool state all survive a rebuild. Before mounting it the first
time, provisioning copies the current `/home` onto the disk and refuses to
mount unless the lab user's `.ssh` is on it -- without that, a bare disk would
bury `authorized_keys` and lock you out on the next connection.

With `KEEP_HOME=no` the disk is scratch space at `/data`, `~/engagements`
points at it, and every rebuild gives you a clean home.

Going from `no` to `yes` happens on the next `make configure`, carrying your
current home across. The other direction cannot be done on a running box, since
it means pulling `/home` out from under every running process, so provisioning
stops with an explanation instead: rebuild with `make destroy` then `make up`.

UTM imports `persist/data.qcow2` into its own VM bundle, so `make destroy`
copies the live disk back out before deleting the VM and the next `make up`
re-attaches it. Worth confirming once on a new UTM version:
`echo loot | sudo tee /data/proof.txt`, then `make destroy && make up`, and
check the file is still there.

## Mullvad

`MULLVAD=yes` installs the Mullvad VPN app and Mullvad Browser
([mullvad.yaml](ansible/roles/attacker/tasks/mullvad.yaml)). Kali packages
neither, and the `.deb` downloads carry no upgrade path, so provisioning adds
Mullvad's own apt repository (signed by
`/usr/share/keyrings/mullvad-keyring.asc`) and both then move with the box's
normal `apt upgrade`. The suite is pinned to `stable` rather than taken from
`lsb_release -cs` the way Mullvad's instructions do, because on Kali that
answers `kali-rolling`, which is not a suite the repository has.

The browser only follows when `ATTACKER_GUI` is a desktop, since it has no
headless use. The VPN is installed either way: without a desktop the `mullvad`
CLI drives the same daemon.

On ARM64 the browser is the alpha channel. Mullvad Browser comes from Tor
Browser, which has no stable Linux `aarch64` release, so the repository carries
stable `mullvad-browser` for `amd64` only and `mullvad-browser-alpha` for
`arm64`. The role picks the alpha package and says so during the run.

Set it up:

```bash
make ssh kali
mullvad account login <account number>
mullvad connect
mullvad status
```

You might want to start the GUI app as well, and make it start at boot.

### Kill switch and SSH

Mullvad's kill switch drops every packet outside the tunnel.

Provisioning therefore turns on Mullvad's local network sharing, which permits
in and outbound traffic on unroutable ranges. That covers the SLIRP subnet the
box sits on, while all internet traffic still goes through the tunnel. Check or
set it by hand with:

```bash
mullvad lan get
mullvad lan set allow
```

Leave `mullvad lockdown-mode` off as well, or the box blocks everything whenever
the tunnel is *down*, which locks out SSH just as thoroughly.

Setting `MULLVAD=no` and running `make configure` is a real removal, not a
skip: both packages are purged and the repository and key are taken back out.
Purging `mullvad-vpn` drops `/etc/mullvad-vpn`, so the logged-in account goes
with it.

`make configure` is the normal way to apply a flip. To run just these tasks,
note that a direct playbook call does not read `lab.conf`, so the value has to
come along:

```bash
ansible-playbook ansible/playbook.yaml --tags mullvad -e attacker_mullvad=true
```

## TO DO

* Bridged mode
  * Couldn't get it going and gave up after a couple of hours
  * Until it works the box has no Layer 2 on the physical LAN, so ARP spoofing,
    Responder and LLMNR/NBNS poisoning have nothing to target

## License

GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
