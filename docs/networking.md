# Networking

The box has one NIC. Its mode comes from `NET_MODE` in `lab.conf` and is passed
straight through to `create-vm.applescript`. That single interface does double
duty: internet access for the guest, and how the host reaches it.

## `nat` (default)

UTM `emulated` mode, i.e. QEMU user-mode networking (SLIRP).

- Outbound internet works and the guest can see the host's LAN, but nothing can
  reach the guest except through the port forward.
- UTM sets up a `127.0.0.1` to guest `22` forward as part of the NIC config. The
  host port is fixed at `HOST_SSH_PORT=2201` (`scripts/lib.sh`), so the box
  lives at `127.0.0.1:2201`.
- Works on any network, including Wi-Fi with client isolation or a captive
  portal, since guest traffic rides out through the host's own stack.
- Hostfwd works only on `emulated`. UTM's `shared`/vmnet-backed modes silently
  ignore port forwards, which is why `nat` maps to `emulated`.

## `bridged`

UTM `bridged` mode, vmnet-bridged on the physical NIC.

- The guest gets its own DHCP address on the physical LAN and behaves like a
  real host on the wire: LLMNR/NBNS poisoning, ARP spoofing and inbound
  callbacks all work.
- There is no `127.0.0.1` port forward here; hostfwd is a SLIRP feature and
  bridged traffic never touches SLIRP. The host reaches the guest by LAN IP on
  port `22`.
- The LAN IP comes from `utmctl ip-address <vm>`, which needs the guest's
  `qemu-guest-agent` (installed by cloud-init) up and reporting.
  `scripts/up.sh` polls for up to 3 minutes before moving on to Ansible.
- Requires DHCP on the network and no client isolation. Coffee-shop and some
  corporate or guest SSIDs isolate clients or block unknown DHCP clients, and
  bridged mode will hang waiting for an address there. If `make up` reports
  "Timed out getting `<vm>` LAN IP", switch back to `nat` or use
  `make console kali`.

## How `make ssh` resolves each mode

`scripts/ssh.sh` branches the same way `up.sh` does:

- `nat`: connects to `127.0.0.1:2201` (`HOST_SSH_PORT`) directly.
- `bridged`: reads `ansible_host` for the VM from the generated inventory
  (`ansible/inventory/hosts.generated.yaml`, written by
  `scripts/gen-inventory.sh` during `make up`). If that is missing or stale, it
  falls back to querying `utmctl ip-address`, on port `22`.

Both paths use the same key (`priv_key()`, derived from `LAB_SSH_KEY`) and
connect as `LAB_USER`.

## First-run UTM caveat

`create-vm.applescript` sets the NIC mode and, for `nat`, the port forward,
using UTM's scripting dictionary property names. Those names are the single
integration point with UTM and can shift between versions. If VM creation fails
with a property error, or a `nat` VM comes up without a working forward, fix the
property there; nothing else in the repo needs to change.

Note also that the first time your terminal drives UTM over AppleScript, macOS
prompts for Automation permission (System Settings > Privacy & Security >
Automation). Until that is approved, `create-vm.applescript`, and therefore
`make up` in either mode, cannot create the VM at all.
