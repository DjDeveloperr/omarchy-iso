#!/bin/bash
#
# plan_free_space_layout() is the one place both free-space installs, the
# wizard's and the unattended cidata one, decide where Omarchy's partitions
# go. Pin what it decides: the largest unallocated region, a 2GiB ESP at its
# aligned start, the root to its aligned end, and a refusal under 32GB.
#
# parted and blkid read image files directly, so this needs no root, no loop
# devices, and no real disk. lsblk only knows block devices, so the two
# queries the planner makes of it are answered from the image instead.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LIB="$ROOT/configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh"

if ! command -v parted >/dev/null 2>&1 || ! command -v blkid >/dev/null 2>&1; then
  echo "SKIP: parted or blkid is not installed"
  exit 0
fi

# shellcheck source=../configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh
source "$LIB"

lsblk() {
  local dev=${!#}
  case "$1 $2" in
    "-dno PTTYPE") blkid -p -s PTTYPE -o value "$dev" 2>/dev/null || true ;;
    "-bdno SIZE") stat -c %s "$dev" ;;
    *) command lsblk "$@" ;;
  esac
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

disk="$WORK/disk.img"
MIB=$((1024 * 1024))
GIB=$((1024 * MIB))
failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

new_disk() {
  rm -f "$disk"
  truncate -s "$1" "$disk"
  created_parts=()
}

mkpart_mib() {
  parted --script "$disk" mkpart "$1" "$2" "$(($3 * MIB))B" "$(($4 * MIB))B"
}

echo "==> a disk with an existing install and free space at the end"
# The shape of a machine that already runs Omarchy and keeps free space for
# test installs: ESP, root, a scratch partition, then nothing.
new_disk 64G
parted --script "$disk" mklabel gpt
mkpart_mib esp fat32 1 2049
mkpart_mib root btrfs 2050 20480
mkpart_mib scratch ext4 20481 25600
plan_free_space_layout
check "plan accepted" "0" "$?"
check "no new partition table" "false" "$needs_mklabel"
check "ESP starts at the free region's first MiB" "$((25601 * MIB))" "$EFI_START_B"
check "ESP is 2GiB" "$((2 * GIB))" "$((EFI_END_B - EFI_START_B))"
check "root starts a MiB past the ESP" "$((EFI_END_B + MIB))" "$ROOT_START_B"
# The GPT backup header and entries take the disk's last 33 sectors.
check "root runs to the last whole MiB" "$((64 * GIB - MIB))" "$ROOT_END_B"
create_partition "$disk" "$EFI_START_B" "$EFI_END_B" fat32 OMARCHY_EFI
check "the planned ESP can be created" "0" "$?"
create_partition "$disk" "$ROOT_START_B" "$ROOT_END_B" btrfs OMARCHY_ROOT
check "the planned root can be created" "0" "$?"
check "existing partitions untouched" "1 2 3 4 5" "$(partition_numbers "$disk" | sort -n | tr '\n' ' ' | sed 's/ $//')"

echo "==> the largest of several free regions"
new_disk 128G
parted --script "$disk" mklabel gpt
mkpart_mib one ext4 1 1024
mkpart_mib two ext4 40961 41984
# Free: about 39GiB between one and two, about 87GiB after two.
plan_free_space_layout
check "plan accepted" "0" "$?"
check "ESP goes in the larger region" "$((41985 * MIB))" "$EFI_START_B"

echo "==> too little free space"
new_disk 40G
parted --script "$disk" mklabel gpt
mkpart_mib one ext4 1 10240
plan_free_space_layout
check "plan refused" "1" "$?"
check "usable size reported" "1" "$((free_space_usable_b > 29 * GIB && free_space_usable_b < 31 * GIB))"

echo "==> a disk with no partition table"
new_disk 64G
plan_free_space_layout
check "plan accepted" "0" "$?"
check "GPT will be created" "true" "$needs_mklabel"
check "ESP starts at 1MiB" "$MIB" "$EFI_START_B"

if (( failures > 0 )); then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
