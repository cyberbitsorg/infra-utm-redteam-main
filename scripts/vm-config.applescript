-- Read or change the CPU/RAM/display of an EXISTING UTM VM (stopped only;
-- create-vm.sh stops it first). Property-name note: see create-vm.applescript.
--   get <name>       -> "<cpu> <ram-mib> <display> <dynres>"
--   set <name> <cpu> <ram-mib> <display> <dynres>  -> "ok"  (dynres true|false)
--   datadisk <name>  -> source path of the 3rd drive (data disk), or ""
on run argv
	set op to item 1 of argv
	set vmName to item 2 of argv

	tell application "UTM"
		set vm to virtual machine named vmName
		if op is "get" then
			set cfg to configuration of vm
			-- Read defensively: a display-less configuration would otherwise
			-- error out the whole reconcile instead of reporting an unknown.
			set ds to displays of cfg
			if (count of ds) < 1 then
				set dispHw to "none"
				set dynRes to "false"
			else
				set dispHw to (hardware of (item 1 of ds)) as text
				if (dynamic resolution of (item 1 of ds)) then
					set dynRes to "true"
				else
					set dynRes to "false"
				end if
			end if
			return ((cpu cores of cfg) as text) & " " & ((memory of cfg) as text) & " " & dispHw & " " & dynRes
		else if op is "set" then
			set cpuCores to (item 3 of argv) as integer
			set memMiB to (item 4 of argv) as integer
			set dispHw to item 5 of argv
			set dynRes to ((item 6 of argv) is "true")
			update configuration vm with {cpu cores:cpuCores, memory:memMiB, displays:{{hardware:dispHw, dynamic resolution:dynRes}}}
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
