#!/usr/bin/env bash
# Unit test: finding the live data disk inside a UTM VM bundle. This is what
# 'make destroy' copies back to persist/, so a silent miss here means the box's
# /home is deleted with the VM. UTM is not involved: the test builds bundles by
# hand and points UTM_DOCUMENTS_DIR at them.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source scripts/lib.sh

fail=0
check() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fail=1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export UTM_DOCUMENTS_DIR="$tmp"

# A UTM bundle: config.plist beside a Data/ folder holding the imported images.
# Drives keep the order create-vm.applescript adds them in (boot, seed, data).
make_bundle() { # <folder> <uuid> <image...>
  local dir="${tmp}/$1.utm" uuid="$2"; shift 2
  local img entries=""
  mkdir -p "${dir}/Data"
  for img in "$@"; do
    : >"${dir}/Data/${img}"
    entries+="<dict><key>ImageName</key><string>${img}</string><key>ImageType</key><string>Disk</string></dict>"
  done
  cat >"${dir}/config.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Drive</key><array>${entries}</array>
  <key>Information</key><dict>
    <key>Name</key><string>$1</string>
    <key>UUID</key><string>${uuid}</string>
  </dict>
</dict></plist>
EOF
  echo "$dir"
}

full="$(make_bundle main-kali AAAA-1111 main-kali.qcow2 main-kali.seed.qcow2 data.qcow2)"
nodata="$(make_bundle other-vm BBBB-2222 other-vm.qcow2 other-vm.seed.qcow2)"

# --- Locating the bundle ----------------------------------------------------
# Matched on UUID, not on folder name: UTM renames the folder when a name is
# reused, and then a name match would copy the wrong VM's disk back.
check "bundle found by uuid" "$full" "$(vm_bundle_dir AAAA-1111)"
check "second bundle found by uuid" "$nodata" "$(vm_bundle_dir BBBB-2222)"
check "unknown uuid finds nothing" "" "$(vm_bundle_dir CCCC-3333)"
check "empty uuid finds nothing" "" "$(vm_bundle_dir "")"

mv "$full" "${tmp}/main-kali 2.utm"
check "bundle found after UTM renamed the folder" "${tmp}/main-kali 2.utm" "$(vm_bundle_dir AAAA-1111)"
mv "${tmp}/main-kali 2.utm" "$full"

# --- Locating the data disk in it -------------------------------------------
check "data disk is the third drive" "${full}/Data/data.qcow2" "$(bundle_data_disk "$full")"
check "no third drive, no data disk" "" "$(bundle_data_disk "$nodata")"
check "missing bundle, no data disk" "" "$(bundle_data_disk "${tmp}/gone.utm")"

rm "${full}/Data/data.qcow2"
check "drive listed but image gone" "" "$(bundle_data_disk "$full")"

exit "$fail"
