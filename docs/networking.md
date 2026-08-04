# Networking

The box has **one NIC**, whose mode is chosen by `NET_MODE` in `lab.conf` and
passed straight through to `create-vm.applescript`. Unlike the multi-VM lab
sibling (which gives every VM two NICs — a NAT uplink plus a shared isolated
lab segment), this repo is a single general-purpose box, so there is exactly
one interface and it does double duty: internet access and how the host
reaches the guest.

## `nat` (default)

UTM `emulated` mode — QEMU user-mode networking (SLIRP).

- The guest gets outbound internet and can see the host's LAN, but nothing on
  the host or LAN can reach the guest directly; the only way in is the port
  forward below.
- UTM sets up a `127.0.0.1` → guest `22` port forward as part of the NIC
  config. The host port is `SSH_PORT_BASE + index` (`SSH_PORT_BASE=2200` by
  default), so the first VM in `LAB_VMS` (`kali`, index 1) is reachable at
  `127.0.0.1:2201`.
- Portable: works on any network, including Wi-Fi with client isolation or a
  captive portal, since the guest's traffic rides out through the host's own
  stack.
- Hostfwd works only on `emulated` — UTM's `shared`/vmnet-backed modes
  silently ignore port forwards, which is why `nat` maps to `emulated` and not
  something vmnet-based.

## `bridged`

UTM `bridged` mode — vmnet-bridged, using the physical NIC directly.

- The guest gets its own address via DHCP on the physical LAN and behaves as
  a first-class host on that network: LLMNR/NBNS poisoning, ARP spoofing,
  and inbound callbacks (reverse shells, etc.) all work the way they would
  from a real machine on the wire.
- There is **no** `127.0.0.1` port forward in this mode — hostfwd is a SLIRP
  feature and bridged traffic never touches SLIRP. The host reaches the guest
  by its LAN IP instead, on the normal port `22`.
- The LAN IP is discovered through `utmctl ip-address <vm>`, which depends on
  the guest's `qemu-guest-agent` (installed by cloud-init) being up and
  reporting. `scripts/up.sh` polls this for up to 3 minutes after creating a
  bridged VM before moving on to Ansible.
- **Requires DHCP on the network, and no client isolation.** Some Wi-Fi
  networks (coffee shops, some corporate/guest SSIDs) isolate clients from
  each other or block unrecognised DHCP clients; bridged mode will hang
  waiting for an address on those networks. If `make up` times out with
  "Timed out getting `<vm>` LAN IP", the network is the likely cause — switch
  back to `nat`, or use `make console kali` for the serial fallback.

## How `make ssh` resolves each mode

`scripts/ssh.sh` branches the same way `up.sh` does:

- **`nat`**: connects to `127.0.0.1:<SSH_PORT_BASE + index>` directly — no
  lookup needed.
- **`bridged`**: reads `ansible_host` for the VM out of the generated
  inventory (`ansible/inventory/hosts.generated.yaml`, written by
  `scripts/gen-inventory.sh` during `make up`). If that's missing or stale
  (e.g. `make up` hasn't run since a reboot), it falls back to querying
  `utmctl ip-address` directly, on port `22`.

Both paths use the same key (`priv_key()`, derived from `LAB_SSH_KEY`) and
connect as `LAB_USER`.

## First-run UTM caveat

`create-vm.applescript` sets the NIC mode and, for `nat`, the port forward,
using UTM's scripting dictionary property names. Those names are the single
integration point with UTM and can shift between UTM versions. If VM creation
fails with a property error, or a `nat` VM comes up without its port forward
working, that's the place to check — adjust the property there only, nothing
else in the repo needs to change.

Also note: the very first time your terminal drives UTM via AppleScript,
macOS prompts for Automation permission (a system dialog, then
System Settings → Privacy & Security → Automation). Until that's approved,
`create-vm.applescript` — and therefore `make up` in either network mode —
cannot create the VM at all.
