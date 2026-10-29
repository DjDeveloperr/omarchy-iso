#!/bin/bash
#
# An appliance image (omarchy-iso-make --appliance) erases a disk with nobody
# choosing it, so appliance_disk() must only ever pick an internal one, and
# names the machine before anyone has: appliance_hostname() takes the onboard
# Ethernet address, as DGX OS names a DGX Spark (spark-7649), never a
# ConnectX fabric port or a USB adapter.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SHARE="$ROOT/configs/airootfs/usr/share/omarchy-iso"

source "$SHARE/disk-partitioning.sh"
source "$SHARE/appliance.sh"

failures=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s:\n    expected: %s\n    got:      %s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export SYSFS_BLOCK="$TMP/block" SYSFS_NET="$TMP/net"
mkdir -p "$SYSFS_BLOCK" "$SYSFS_NET" "$TMP/bus/pci" "$TMP/bus/usb"

lsblk() {
  case "$*" in
    "-dbpno NAME,TYPE,SIZE,RM,TRAN") printf '%s\n' "$LSBLK_DISKS" ;;
    "-dno RM,TRAN "*) awk -v d="${*: -1}" '$1 == d { print $4, $5 }' <<<"$LSBLK_DISKS" ;;
    *) return 1 ;;
  esac
}

echo "==> the disk it erases"
LSBLK_DISKS=$'/dev/sda     disk  32017047552 1 usb
/dev/nvme0n1 disk 4000787030016 0 nvme'
check "the internal NVMe, never the boot stick" "/dev/nvme0n1" "$(appliance_disk /dev/sda)"

LSBLK_DISKS=$'/dev/sda disk 32017047552 1 usb
/dev/sdb disk 64023257088 0 usb'
check "nothing when only USB disks are left" "" "$(appliance_disk /dev/sda)"

# iface <name> <bus> <vendor> <address> [wireless]
iface() {
  local dir="$SYSFS_NET/$1"
  mkdir -p "$dir/device"
  ln -s "$TMP/bus/$2" "$dir/device/subsystem"
  printf '%s\n' "$3" >"$dir/device/vendor"
  printf '%s\n' "$4" >"$dir/address"
  [[ -z ${5:-} ]] || mkdir "$dir/wireless"
}

echo "==> the name it waits under"
# spark-7649's interfaces: four ConnectX-7 functions, the Realtek port, Wi-Fi.
iface enP2p1s0f0np0 pci 0x15b3 4c:bb:47:eb:76:4e
iface enp1s0f0np0 pci 0x15b3 4c:bb:47:eb:76:4a
iface enP7s7 pci 0x10ec 4c:bb:47:eb:76:49
iface wlP9s9 pci 0x14c3 f0:68:e3:d7:bc:74 wireless
iface enx00e04c680001 usb 0x0bda 00:e0:4c:68:00:01
mkdir -p "$SYSFS_NET/lo"
printf '00:00:00:00:00:00\n' >"$SYSFS_NET/lo/address"

appliance_platform() { printf 'aarch64-gb10\n'; }
check "a GB10 is spark-<onboard Ethernet>" "spark-7649" "$(appliance_hostname)"

appliance_platform() { printf 'aarch64-n1x\n'; }
check "anything else is omarchy-<onboard Ethernet>" "omarchy-7649" "$(appliance_hostname)"

rm -rf "$SYSFS_NET/enP7s7"
check "Wi-Fi stands in without onboard Ethernet" "omarchy-bc74" "$(appliance_hostname)"

rm -rf "$SYSFS_NET/wlP9s9"
check "a random suffix without either" "1" "$(appliance_hostname | grep -cE '^omarchy-[0-9a-f]{4}$')"

if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
