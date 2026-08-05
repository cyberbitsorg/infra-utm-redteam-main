# Extending

v1 of this box ships none of the below: no baked-in personal identity, no VPN,
no second machine. They are documented as the intended extension points, so
adding them does not fight the existing design.

## Personal dotfiles and git identity

Two ways to carry personal configuration into the guest, matching the two
persistence models in `docs/host-integration.md`:

- Via `share/` (works with any `PERSIST_MODE`): drop your dotfiles or a
  bootstrap script into `share/` on the host. It is live-mounted at `~/share`
  in the guest, so you can symlink from there
  (`ln -s ~/share/.gitconfig ~/.gitconfig`) after every fresh boot. Nothing to
  rebuild; just re-run the symlink step, or a small script that does it, after
  each `make up`, since `PERSIST_MODE=data` gives you a clean home every time.
- Via `PERSIST_MODE=home`: set it in `lab.conf` before the first `make up` (or
  `make destroy && make up` to switch an existing box), then configure the guest
  once. Dotfiles, git identity, SSH keys and shell history survive every
  rebuild, because the persistent disk is `/home`. Trade-off: no clean home on
  rebuild, and a stale or broken home persists just as well as a good one.

Pick `share/` for a clean box every rebuild with config applied by a repeatable
step; pick `PERSIST_MODE=home` for a guest that remembers everything, like a
daily-driver machine.

## HTB / THM VPN

Nothing VPN-specific is installed by default. To connect to a Hack The Box or
TryHackMe lab network:

1. Check `openvpn` is available in the guest (usually pulled in transitively by
   `kali-linux-default`/`large`; otherwise `sudo apt install openvpn`).
2. Drop your `.ovpn` config into `share/` on the host. It appears at
   `~/share/<name>.ovpn` in the guest.
3. Connect from the guest:

   ```bash
   sudo openvpn --config ~/share/<name>.ovpn
   ```

Keeping the config in `share/` means it survives `make destroy`, since the
folder lives on the Mac, without needing `PERSIST_MODE=home`. Connecting the VPN
automatically on boot is a small addition to the `attacker` role (a systemd unit
or an `openvpn@` instance), left out here because VPN targets and credentials
are personal, not something to bake into a shared repo.

## Need more than one machine?

This repo is deliberately a single box. `lab.conf` describes exactly one VM
(`VM_NAME`, `VM_CPU`, `VM_RAM`, `VM_DISK_GB`) and the scripts operate on it
directly: no fleet array, no per-entry parser, no index-based MAC/port math.
That is the whole point of the simplification.

If you want several machines, use the sibling `infra-utm-redteam-lab`. It is
built for exactly that: a `LAB_VMS` fleet, per-role base images, an isolated lab
segment, and vulnerable targets to attack.

A second box from this repo is a code change, not a config edit. The fixed
`VM_MAC` and `HOST_SSH_PORT` constants and the single `data_disk_path()`
(`persist/data.qcow2`) in `scripts/lib.sh` all assume one machine, so two VMs
would collide on the MAC, the host SSH port and the persistent disk. At that
point you are rebuilding what the lab sibling already provides, so prefer it.
