-- Read or change the CPU/RAM/display of an EXISTING UTM VM.
-- Usage: vm-config.applescript get <name>       -> prints "<cpu> <ram-mib> <display>"
--        vm-config.applescript set <name> <cpu> <ram-mib> <display> -> prints "ok"
--        vm-config.applescript datadisk <name>  -> prints the source path
--        of the 3rd drive (the data disk), or "" if fewer than 3 drives
--
-- UTM only allows `update configuration` while the VM is stopped; the caller
-- (scripts/create-vm.sh) stops it first.
--
-- NOTE: This and create-vm.applescript are the only places that talk to UTM.
-- Property names follow the UTM AppleScript dictionary
-- (docs.getutm.app/scripting/reference). If a future UTM version rejects a
-- key, adjust it here only.
on run argv
	set op to item 1 of argv
	set vmName to item 2 of argv

	tell application "UTM"
		set vm to virtual machine named vmName
		if op is "get" then
			set cfg to configuration of vm
			-- A VM always has exactly one display here, but read defensively:
			-- a display-less configuration would otherwise error out the whole
			-- reconcile instead of just reporting an unknown value.
			set ds to displays of cfg
			if (count of ds) < 1 then
				set dispHw to "none"
			else
				set dispHw to (hardware of (item 1 of ds)) as text
			end if
			return ((cpu cores of cfg) as text) & " " & ((memory of cfg) as text) & " " & dispHw
		else if op is "set" then
			set cpuCores to (item 3 of argv) as integer
			set memMiB to (item 4 of argv) as integer
			set dispHw to item 5 of argv
			update configuration vm with {cpu cores:cpuCores, memory:memMiB, displays:{{hardware:dispHw}}}
			return "ok"
		else if op is "datadisk" then
			set cfg to configuration of vm
			set ds to drives of cfg
			if (count of ds) < 3 then return ""
			return POSIX path of (source of (item 3 of ds))
		else
			error "vm-config: unknown op " & op
		end if
	end tell
end run
