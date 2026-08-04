-- Create one QEMU aarch64 Kali VM in UTM.
--
-- ONE NIC, mode chosen by netMode:
--   "nat"     : "emulated" (QEMU user/SLIRP) with a 127.0.0.1 SSH port-forward.
--               The hostfwd works ONLY on "emulated"; UTM "shared"/vmnet modes
--               silently drop port forwards.
--   "bridged" : "bridged" (vmnet-bridged) -- the box gets its own DHCP address
--               on the physical LAN. No port-forward is possible here.
--
-- Optional 3rd drive: the persistent data disk (kept in persist/). Optional
-- directory share: the host-side share/ folder.
--
-- This and vm-config.applescript are the ONLY UTM integration points. Property
-- names follow the UTM scripting dictionary (docs.getutm.app/scripting/reference).
-- If a UTM version rejects a key, adjust it here only. See Step 3 validation.
on run argv
	set vmName to item 1 of argv
	set diskPath to item 2 of argv
	set seedPath to item 3 of argv
	set memMiB to (item 4 of argv) as integer
	set cpuCores to (item 5 of argv) as integer
	set macAddr to item 6 of argv
	set sshPort to (item 7 of argv) as integer
	set netMode to item 8 of argv
	set dataDiskPath to item 9 of argv
	set sharePath to item 10 of argv

	set diskFile to POSIX file diskPath
	set seedFile to POSIX file seedPath

	tell application "UTM"
		-- NIC per mode.
		if netMode is "bridged" then
			set nics to {{mode:bridged, address:macAddr}}
		else
			set nics to {{mode:emulated, address:macAddr, port forwards:{{host address:"127.0.0.1", host port:sshPort, guest port:22}}}}
		end if

		-- Drives: OS + seed (non-removable so UTM uses VirtIO, not a USB CD-ROM
		-- that hangs boot on UTM 4.7.x), plus the optional data disk as a 3rd
		-- non-removable VirtIO drive.
		if dataDiskPath is not "" then
			set theDrives to {{removable:false, source:diskFile}, {removable:false, source:seedFile}, {removable:false, source:(POSIX file dataDiskPath)}}
		else
			set theDrives to {{removable:false, source:diskFile}, {removable:false, source:seedFile}}
		end if

		set cfg to {name:vmName, architecture:"aarch64", uefi:true, memory:memMiB, cpu cores:cpuCores, drives:theDrives, displays:{{hardware:"virtio-gpu-pci"}}, network interfaces:nics}

		-- Optional host directory share. The exact key is confirmed by the Step 3
		-- validation; if UTM's dictionary names it differently, change it here.
		if sharePath is not "" then
			set cfg to cfg & {directory shares:{{source:(POSIX file sharePath)}}}
		end if

		set vm to make new virtual machine with properties {backend:qemu, configuration:cfg}
		return id of vm
	end tell
end run
