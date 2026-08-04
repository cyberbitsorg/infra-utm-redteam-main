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

## Growing into a fleet

`lab.conf`'s `LAB_VMS` array is a single entry today:

```bash
LAB_VMS=(
  "kali:attacker"
)
```

It's kept as an array specifically so it can grow. The entry format is
`"name:role [cpu=N] [ram=MiB] [disk=GB]"` — the resource fields are optional
and fall back to `LAB_CPU`/`LAB_RAM`/`LAB_DISK_GB`, so a new entry only needs
to spell out what differs from the defaults:

```bash
LAB_VMS=(
  "kali:attacker"
  "kali2:attacker cpu=4 ram=4096"
)
```

A few things to know before doing this:

- Every entry currently maps to the same base image and the same `attacker`
  role — `role_image()` in `scripts/lib.sh` is hardcoded to the Kali image
  ("Every VM in this repo is Kali; kept as a function so the fleet can
  grow."), and `attacker` is the only Ansible role wired into
  `ansible/playbook.yaml`. A second Kali box running the same role works as
  shown above. A genuinely different role (a different base image, a
  different Ansible role) needs `role_image()` and the playbook extended
  first — follow the pattern in the `infra-utm-redteam-lab` sibling, which
  already runs a multi-role fleet this way.
- `data_disk_path()` in `scripts/lib.sh` returns a single fixed path,
  `persist/data.qcow2`, shared by every VM in `LAB_VMS`. That's correct for
  today's one-VM build; before running more than one VM at once, key it by VM
  name (e.g. `persist/<name>-data.qcow2`) so each machine gets its own
  persistent disk instead of contending for one.
- In `nat` mode, each additional VM gets the next `SSH_PORT_BASE + index`
  port automatically; in `bridged` mode, each gets its own DHCP lease with no
  extra configuration needed.
- `make ssh <name>` and `make console <name>` already take the short name as
  an argument, so a bigger fleet doesn't need new tooling for day-to-day use
  — only `up.sh`'s per-VM loop, which already exists, does the work.
