# Host integration

Three features tie the box to the macOS host: clipboard sharing, a live
shared folder, and a data disk that survives a full rebuild. None of these
exist in `infra-utm-anon-egress` (host integration would undermine the
anonymity invariant there); they're all fine here, since this box has no such
invariant to protect.

## Clipboard

Controlled by `CLIPBOARD` in `lab.conf` (`yes` by default). When enabled,
`ansible/roles/attacker/tasks/integration.yaml` installs `spice-vdagent` and
enables the `spice-vdagentd` service. Together with UTM's SPICE display
backend, this gives ordinary copy/paste between macOS and the guest XFCE
desktop — no manual steps in the guest.

Setting `CLIPBOARD=no` and re-running `make configure` purges the package and
leaves clipboard sharing off. Check it's running in the guest with:

```bash
systemctl is-active spice-vdagentd
```

## Shared folder

The host-side `share/` directory (repo root, gitignored except for a
`.gitkeep`) is passed to `create-vm.applescript` as a UTM directory share and
mounted inside the guest at `~/share`.

- `create-vm.applescript` adds `directory shares: {{source: <share/>}}` to the
  VM's configuration at creation time.
- `integration.yaml` mounts it in the guest over 9p (`trans=virtio,
  version=9p2000.L`), with `nofail` and `failed_when: false` — if the tag
  isn't present, the play continues rather than failing the whole run.
- **This is a first-run validation item.** UTM has exposed host directories
  through more than one mechanism across versions (SPICE WebDAV vs. a 9p/
  virtio-fs VirtIO tag), and which one a given UTM release actually offers
  depends on the version installed. `create-vm.applescript`'s comments call
  this out explicitly: if 9p doesn't come up, that's where to check and
  adjust the share configuration.

To check whether it's mounted after `make up`:

```bash
make ssh kali
mountpoint -q ~/share && echo "share mounted" || echo "share not mounted"
```

If it isn't, drop files into `share/` on the host is still possible, they
just won't be visible in the guest until the mount is fixed — use
`make console kali` plus manual inspection, or fall back to `scp` over the
SSH port, as a workaround.

## Persistence (`PERSIST_MODE`)

A second VirtIO disk, `persist/data.qcow2`, is created once
(`scripts/create-vm.sh`, size `DATA_DISK_GB`, default `40`, never shrunk) and
lives **outside** the disposable OS disk's lifecycle. `integration.yaml`
formats it ext4 on first use (only if it has no filesystem yet, so a
reconfigure never wipes existing data) and mounts it according to
`PERSIST_MODE`:

- **`data`** (default): mounted at `/data`, with `~/engagements` symlinked to
  it. The OS disk — and therefore `/home`, dotfiles, shell history, tool
  state — is clean on every rebuild; only whatever lives under `/data`
  persists.
- **`home`**: the persistent disk is mounted at `/home` itself, so dotfiles,
  SSH keys, and tool state all survive a rebuild. Caveat, called out in
  `integration.yaml`: on a brand-new (empty) data disk, mounting it at
  `/home` shadows the cloud-init user's home directory with an empty one. If
  you need the account's default skeleton files present on first boot under
  `home` mode, copy `/etc/skel` into the mounted disk before it's used, or
  accept an empty home on the very first boot.

### What survives `make destroy`

`scripts/destroy.sh` deletes the VM and wipes `generated/` (the disposable OS
staging disk and cloud-init seed) and the generated inventory. It explicitly
**keeps**:

- `images/` — the base image, untouched
- `persist/` — the data disk, via the round-trip below

### The destroy → copy-back → re-import round-trip

UTM imports `persist/data.qcow2` into its own VM bundle when the VM is
created, so the *live*, currently-being-written-to copy of the data disk
lives inside that bundle, not at `persist/data.qcow2` on disk. If
`destroy.sh` simply deleted the VM, that live copy would go with it.

To avoid that, `destroy.sh`:

1. Queries the VM bundle for its data-disk path
   (`scripts/vm-config.applescript datadisk <vm>`).
2. Copies that file back out to `persist/data.qcow2` (via a `.new` temp file,
   renamed into place, so a failed copy never corrupts the existing one).
3. Only then stops and deletes the VM.

On the next `make up`, `scripts/create-vm.sh` sees `persist/data.qcow2`
already exists and reuses it rather than creating a fresh one; UTM re-imports
it as the VM's third drive. The result: a rebuilt box with a brand-new OS
disk but the same data disk.

**This copy-back is a first-run validation item** — it depends on
`vm-config.applescript`'s `datadisk` query correctly identifying the right
disk inside whatever UTM bundle layout your UTM version uses. To confirm it
works:

```bash
make ssh kali
echo "loot" | sudo tee /data/proof.txt   # persist_mode=data
exit
make destroy   # type yes
make up
make ssh kali
cat /data/proof.txt   # should print "loot"
```

**Fallback if this round-trip proves unreliable:** fall back to host-side
persistence only — keep loot in `share/` (which lives on the Mac and is never
touched by `make destroy`) instead of relying on the data disk, and treat the
data disk as bound to the OS disk's lifecycle until the round-trip is fixed.
