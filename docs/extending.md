# Extending

v1 of this box ships none of the below built in — no baked-in personal
identity, no VPN, no second machine. They're documented here as the intended
extension points instead, so adding them doesn't fight the existing design.

## Personal dotfiles and git identity

The box gives you two ways to carry personal configuration into the guest,
matching the two persistence models in `docs/host-integration.md`:

- **Via `share/`** (works regardless of `PERSIST_MODE`): drop your dotfiles
  or a bootstrap script into `share/` on the host. It's live-mounted at
  `~/share` in the guest, so you can symlink from there —
  `ln -s ~/share/.gitconfig ~/.gitconfig`, etc. — after every fresh boot.
  Nothing to rebuild; just re-run the symlink step (or a small script that
  does it) after each `make up`, since `PERSIST_MODE=data` gives you a clean
  home every time.
- **Via `PERSIST_MODE=home`**: set this in `lab.conf` before the first
  `make up` (or `make destroy && make up` to switch an existing box), then
  configure the guest once — dotfiles, git identity, SSH keys, shell history —
  and it survives every subsequent `make destroy` + `make up`, because the
  persistent disk *is* `/home`. Trade-off: you no longer get a clean home on
  rebuild, and a stale or misconfigured home persists just as much as a good
  one.

Pick `share/` if you want a clean box every rebuild with config applied by a
repeatable step; pick `PERSIST_MODE=home` if you want the guest to remember
everything, like a real daily-driver machine.

## HTB / THM VPN

Nothing VPN-specific is installed by default. To connect to a Hack The Box or
TryHackMe lab network:

1. Make sure `openvpn` is available in the guest (it's typically already
   pulled in transitively by `kali-linux-default`/`large`; if not,
   `sudo apt install openvpn`).
2. Drop your `.ovpn` config file into `share/` on the host — it appears at
   `~/share/<name>.ovpn` in the guest.
3. Connect from the guest:

   ```bash
   sudo openvpn --config ~/share/<name>.ovpn
   ```

Keeping the config in `share/` means it survives `make destroy` (the folder
lives on the Mac, untouched by teardown) without needing `PERSIST_MODE=home`.
If you want the VPN connected automatically on boot, that's a small addition
to the `attacker` role (a systemd unit or an `openvpn@` instance) — not
included here since VPN targets and credentials are personal, not something
to bake into a shared repo.

## Need more than one machine?

This repo is deliberately a single box. `lab.conf` describes exactly one VM
(`VM_NAME`, `VM_CPU`, `VM_RAM`, `VM_DISK_GB`), and the scripts operate on that
one VM directly — there is no fleet array, no per-entry parser, and no
index-based MAC/port math. That is the whole point of the simplification: a
main attack box you rebuild identically, without the multi-machine plumbing.

**If you want several machines, use the sibling `infra-utm-redteam-lab`.** It
is built for exactly that — a `LAB_VMS` fleet, per-role base images, an
isolated lab segment, and vulnerable targets to attack. Reaching for it is the
right move rather than re-growing a fleet here.

If you genuinely want a second box from *this* repo, the honest answer is that
it is a code change, not a config edit. You would reintroduce per-VM
configuration and give each VM its own identity in `scripts/lib.sh`: the fixed
`VM_MAC` and `HOST_SSH_PORT` constants and the single `data_disk_path()`
(`persist/data.qcow2`) each assume one machine, so two VMs would collide on the
MAC, the host SSH port, and the persistent disk. At that point you are
rebuilding what the lab sibling already provides — prefer it.
