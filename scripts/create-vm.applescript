-- Create the QEMU aarch64 Kali VM in UTM. One NIC in "emulated" (QEMU SLIRP)
-- mode with a 127.0.0.1 SSH port-forward; hostfwd works ONLY there, as UTM's
-- vmnet modes drop port forwards.
--
-- This and vm-config.applescript are the only UTM integration points. Property
-- names follow docs.getutm.app/scripting/reference; if a UTM version rejects a
-- key, adjust it in these two files only.
on run argv
	set vmName to item 1 of argv
	set diskPath to item 2 of argv
	set seedPath to item 3 of argv
	set memMiB to (item 4 of argv) as integer
	set cpuCores to (item 5 of argv) as integer
	set macAddr to item 6 of argv
	set sshPort to (item 7 of argv) as integer
	set dataDiskPath to item 8 of argv
	set sharePath to item 9 of argv
	set displayHw to item 10 of argv
	set dynRes to ((item 11 of argv) is "true")

	-- Every POSIX file coercion has to happen outside the tell block: inside it
	-- a bare "POSIX file x" in a record is sent to UTM to resolve and fails with
	-- "Can't get POSIX file ..." (-1728).
	set diskFile to POSIX file diskPath
	set seedFile to POSIX file seedPath
	set dataFile to missing value
	if dataDiskPath is not "" then set dataFile to POSIX file dataDiskPath

	tell application "UTM"
		set nics to {{mode:emulated, address:macAddr, port forwards:{{host address:"127.0.0.1", host port:sshPort, guest port:22}}}}

		-- Non-removable so UTM uses VirtIO and not a USB CD-ROM, which hangs boot
		-- on UTM 4.7.x. The data disk is the 3rd drive; lib.sh's bundle_data_disk
		-- reads it back by that position, so this order is load-bearing.
		if dataFile is not missing value then
			set theDrives to {{removable:false, source:diskFile}, {removable:false, source:seedFile}, {removable:false, source:dataFile}}
		else
			set theDrives to {{removable:false, source:diskFile}, {removable:false, source:seedFile}}
		end if

		-- displayHw and dynRes come from VM_DISPLAY and DISPLAY_RESOLUTION in
		-- lib.sh; see the notes there for why the device is the non-GL one.
		set cfg to {name:vmName, architecture:"aarch64", uefi:true, memory:memMiB, cpu cores:cpuCores, drives:theDrives, displays:{{hardware:displayHw, dynamic resolution:dynRes}}, network interfaces:nics}

		-- The qemu backend has no "directory shares" property, only "directory
		-- share mode", and passing a source path anyway fails creation with
		-- -1700. So all this can do is switch VirtFS on, which gives the guest
		-- the "share" tag integration.yaml mounts; the host folder is picked
		-- once in UTM's VM settings and sticks with the VM.
		if sharePath is not "" then
			set cfg to cfg & {directory share mode:VirtFS}
		end if

		set vm to make new virtual machine with properties {backend:qemu, configuration:cfg}
		return id of vm
	end tell
end run
