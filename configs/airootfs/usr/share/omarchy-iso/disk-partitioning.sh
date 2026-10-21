# Disk partitioning helpers, shared by the ISO configurator and its tests.
#
# The rule here is: never predict a partition number. parted fills the lowest
# free GPT slot, not "highest existing + 1", so any disk whose numbering has a
# hole — exactly what deleting a partition to free space leaves behind, which
# is what our own partition tool tells the user to do — hands back a number we
# did not choose. Everything below reads back what was actually created.
#
# Sourced, not executed. The configurator defines abort() and
# disk_abort_hook(); tests get the plain fallbacks.

# Partitions this run created, in creation order. rollback_created_parts()
# undoes exactly these and nothing else.
created_parts=()

# Set by create_partition() instead of being printed: a command substitution
# would run it in a subshell and lose the created_parts bookkeeping.
created_partition_number=""

# Compute partition device path, handling NVMe/mmcblk's pN naming.
partition_path() {
  local _disk="$1" _num="$2"
  if [[ "$_disk" == *nvme* || "$_disk" == *mmcblk* ]]; then
    echo "${_disk}p${_num}"
  else
    echo "${_disk}${_num}"
  fi
}

# Partition numbers as the on-disk GPT reports them. parted rather than lsblk
# on purpose: this is the table parted itself is about to modify, so discovery
# never depends on the kernel having re-read the partition table yet — and the
# same code works against an image file in tests, where lsblk sees nothing.
partition_numbers() {
  parted -ms "$1" unit B print 2>/dev/null | tail -n +3 | cut -d: -f1
}

partition_size_bytes() {
  parted -ms "$1" unit B print 2>/dev/null |
    awk -F: -v n="$2" '$1 == n { gsub(/B/, "", $4); print $4; exit }'
}

# Fail loudly. The former version looped over sleep and returned its status,
# so a device that never appeared was indistinguishable from one that did.
wait_for_device() {
  local i
  for i in $(seq 1 10); do
    [[ -b "$1" ]] && return 0
    udevadm settle 2>/dev/null || true
    sleep 1
  done
  return 1
}

_disk_abort() {
  if declare -F disk_abort_hook >/dev/null; then
    disk_abort_hook "$1"
  elif declare -F abort >/dev/null; then
    abort "$1"
  fi
  echo "Error: $1" >&2
  exit 1
}

# Run a disk-writing command, fold its stderr into stdout, and abort on a
# non-zero exit. The fold matters: .automated_script.sh tees stdout into
# /var/log/omarchy-install.log but sends stderr straight to the tty (gum draws
# its TUI there), so an unwrapped failure leaves no trace in the log the user
# uploads — and the configurator's next screen clears it off the display too.
disk_step() {
  local desc="$1"
  shift
  local output status=0
  output=$("$@" 2>&1) || status=$?
  [[ -n $output ]] && printf '%s\n' "$output"
  (( status == 0 )) && return 0
  _disk_abort "$desc failed (exit $status)"
}

# Create one partition and report the number parted actually assigned.
# Returns non-zero without touching created_parts if anything looks wrong;
# the caller decides how loudly to fail.
create_partition() {
  local disk="$1" start="$2" end="$3" fstype="$4" name="$5"
  local before after num actual want tolerance

  created_partition_number=""

  # Lexicographic sort on both sides: comm needs its inputs ordered the same
  # way it compares them, and `sort -n` (1, 2, 10) is not that order.
  before=$(partition_numbers "$disk" | sort)

  parted --script "$disk" mkpart primary "$fstype" "${start}B" "${end}B" || return 1
  partprobe "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || true

  after=$(partition_numbers "$disk" | sort)
  num=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
  [[ -n $num ]] || return 1

  # The number must be genuinely new. This is the safety property that keeps a
  # numbering mistake from ever formatting a partition somebody else is using;
  # it is cheaper and more reliable than sniffing the target for signatures,
  # which would false-positive on remnants left in freed space.
  grep -qx "$num" <<<"$before" && return 1

  actual=$(partition_size_bytes "$disk" "$num")
  [[ -n $actual ]] || return 1
  want=$((end - start))
  tolerance=$((1024 * 1024))
  (( actual >= want - tolerance && actual <= want + tolerance )) || return 1

  parted --script "$disk" name "$num" "$name" || true

  created_parts+=("$num")
  created_partition_number="$num"
}

# Undo the partitions this run created, highest number first. Scoped strictly
# to created_parts: without this, a failed install leaves the user's freed
# space occupied by orphans, and the retry reports "not enough free space"
# with no way to connect that to what just happened.
rollback_created_parts() {
  local disk="$1" n
  (( ${#created_parts[@]} > 0 )) || return 0
  for n in $(printf '%s\n' "${created_parts[@]}" | sort -rn); do
    parted --script "$disk" rm "$n" >/dev/null 2>&1 || true
  done
  partprobe "$disk" 2>/dev/null || true
  created_parts=()
}

# BitLocker writes the "-FVE-FS-" signature at offset 3 of the partition.
detect_bitlocker() {
  local p sig
  for p in $(lsblk -lnpo NAME,TYPE "$disk" | awk '$2=="part"{print $1}'); do
    sig=$(dd if="$p" bs=1 skip=3 count=8 status=none 2>/dev/null | tr -d '\0')
    if [[ "$sig" == "-FVE-FS-" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

# ------------------------------------------------------- free-space install
#
# Both free-space installs, the wizard's and the unattended one
# (omarchy-cidata-free-space), lay out and prepare the target with the two
# functions below, so they put the same partitions in the same place.

_disk_progress() {
  if declare -F step >/dev/null; then
    step "$1"
  else
    echo "$1"
  fi
}

# Plan Omarchy's two partitions in the largest unallocated region of $disk: a
# 2GiB ESP, then the root to the end of the region. Sets needs_mklabel,
# INSTALL_MAX_B and the EFI_/ROOT_ bounds. Returns 1 when the region can't
# hold the 32GB minimum, with the usable size in free_space_usable_b.
plan_free_space_layout() {
  # An unlabeled disk has no partition table for parted to scan, so we
  # synthesize a whole-disk free region and mklabel gpt before mkpart.
  local FREE_SPACE_INFO pt_type disk_size_b
  needs_mklabel=false
  free_space_usable_b=0
  pt_type=$(lsblk -dno PTTYPE "$disk" 2>/dev/null)
  if [[ -z "$pt_type" ]]; then
    disk_size_b=$(lsblk -bdno SIZE "$disk" 2>/dev/null)
    if [[ -n "$disk_size_b" && "$disk_size_b" -gt 0 ]]; then
      local _mib=$((1024 * 1024))
      local _start=$_mib
      local _end=$(( (disk_size_b - _mib) / _mib * _mib ))
      FREE_SPACE_INFO="$_start $_end $((_end - _start))"
      needs_mklabel=true
    fi
  else
    # -s (script mode) keeps parted from prompting on stderr for warnings
    # like a stale GPT backup; without it the configurator hangs invisibly.
    FREE_SPACE_INFO=$(parted -ms "$disk" unit B print free </dev/null 2>/dev/null | \
      awk -F: '
        $NF ~ /free/ {
          start=$2; end=$3; size=$4;
          gsub(/B/, "", start);
          gsub(/B/, "", end);
          gsub(/B/, "", size);
          if (size+0 > max_size+0) {
            max_size=size; max_start=start; max_end=end;
          }
        }
        END {
          if (max_size+0 > 0) printf "%s %s %s\n", max_start, max_end, max_size;
        }')
  fi

  [[ -n "$FREE_SPACE_INFO" ]] || return 1

  local FREE_START_B FREE_END_B FREE_SIZE_B
  read -r FREE_START_B FREE_END_B FREE_SIZE_B <<<"$FREE_SPACE_INFO"

  local mib=$((1024 * 1024)) gib=$((1024 * 1024 * 1024))
  local ALIGN=$mib
  local EFI_SIZE_B=$((2 * gib))
  local MIN_INSTALL_B=$((32 * gib))    # Minimum total Omarchy allocation

  EFI_START_B=$(( (FREE_START_B + ALIGN - 1) / ALIGN * ALIGN ))
  EFI_END_B=$((EFI_START_B + EFI_SIZE_B))
  ROOT_START_B=$(( (EFI_END_B + 1 + ALIGN - 1) / ALIGN * ALIGN ))
  ROOT_END_B=$((FREE_END_B / ALIGN * ALIGN))

  if (( ROOT_END_B <= ROOT_START_B )); then
    free_space_usable_b=$FREE_SIZE_B
    return 1
  fi

  INSTALL_MAX_B=$((ROOT_END_B - EFI_START_B))
  free_space_usable_b=$INSTALL_MAX_B

  (( INSTALL_MAX_B >= MIN_INSTALL_B ))
}

# Create, format and mount the planned layout at /mnt: partitions, LUKS2 when
# encrypt_installation is true (keyed with $password), Btrfs subvolumes and
# the ESP at /mnt$esp_mount_in_target. Sets efi_part_num, root_part_num,
# efi_dev, root_partition_device and root_mapper. Fails through
# disk_abort_hook, which undoes the partitions this run created.
prepare_free_space_target() {
  local subvol

  _disk_progress "Creating partitions on $disk"
  if $needs_mklabel; then
    disk_step "initializing GPT on $disk" parted --script "$disk" mklabel gpt
    partprobe "$disk" 2>/dev/null || true
    sleep 1
  fi

  # create_partition reports the number parted actually used; nothing here
  # may assume it. It sets created_partition_number rather than printing so
  # the rollback bookkeeping survives (a $(...) would subshell it away).
  create_partition "$disk" "$EFI_START_B" "$EFI_END_B" fat32 OMARCHY_EFI ||
    _disk_abort "Could not create the EFI partition on $disk"
  efi_part_num="$created_partition_number"

  create_partition "$disk" "$ROOT_START_B" "$ROOT_END_B" btrfs OMARCHY_ROOT ||
    _disk_abort "Could not create the root partition on $disk"
  root_part_num="$created_partition_number"

  disk_step "flagging partition $efi_part_num as ESP" \
    parted --script "$disk" set "$efi_part_num" esp on

  efi_dev=$(partition_path "$disk" "$efi_part_num")
  root_partition_device=$(partition_path "$disk" "$root_part_num")

  partprobe "$disk"
  sync
  sleep 2

  wait_for_device "$efi_dev" || _disk_abort "EFI partition $efi_dev never appeared"
  wait_for_device "$root_partition_device" ||
    _disk_abort "Root partition $root_partition_device never appeared"

  # Both partitions are ours and brand new, but the space they occupy may
  # carry signatures from whatever was deleted to free it.
  disk_step "clearing stale signatures on $efi_dev" wipefs -af "$efi_dev"
  disk_step "clearing stale signatures on $root_partition_device" wipefs -af "$root_partition_device"

  if [[ "$encrypt_installation" == "true" ]]; then
    _disk_progress "Setting up LUKS2 on $root_partition_device"
    # Kept as pipes rather than routed through disk_step: the passphrase must
    # not become an argv the process table can show. Folding stderr into
    # stdout still lands any error in the install log.
    if ! printf "%s" "$password" |
      cryptsetup luksFormat --type luks2 --batch-mode "$root_partition_device" - 2>&1; then
      _disk_abort "Formatting LUKS2 on $root_partition_device failed"
    fi
    if ! printf "%s" "$password" |
      cryptsetup open "$root_partition_device" omarchy_root - 2>&1; then
      _disk_abort "Opening the encrypted root on $root_partition_device failed"
    fi
    root_mapper="/dev/mapper/omarchy_root"
  else
    root_mapper="$root_partition_device"
  fi

  _disk_progress "Creating Btrfs filesystem and subvolumes"
  disk_step "creating the Btrfs filesystem on $root_mapper" \
    mkfs.btrfs -f -L OMARCHY "$root_mapper"
  wait_for_device "$root_mapper" || _disk_abort "Root device $root_mapper never appeared"

  mkdir -p /mnt/btrfs-root
  disk_step "mounting $root_mapper" mount "$root_mapper" /mnt/btrfs-root
  for subvol in @ @home @log @pkg; do
    disk_step "creating subvolume $subvol" btrfs subvolume create "/mnt/btrfs-root/$subvol"
  done
  umount /mnt/btrfs-root
  rmdir /mnt/btrfs-root

  disk_step "mounting the target root" \
    mount -o noatime,compress=zstd,subvol=@ "$root_mapper" /mnt
  mkdir -p /mnt/home /mnt/var/log /mnt/var/cache/pacman/pkg /mnt"$esp_mount_in_target"
  disk_step "mounting /home" \
    mount -o noatime,compress=zstd,subvol=@home "$root_mapper" /mnt/home
  disk_step "mounting /var/log" \
    mount -o noatime,compress=zstd,subvol=@log "$root_mapper" /mnt/var/log
  disk_step "mounting the package cache" \
    mount -o noatime,compress=zstd,subvol=@pkg "$root_mapper" /mnt/var/cache/pacman/pkg

  disk_step "creating the ESP filesystem on $efi_dev" mkfs.fat -F32 -n OMARCHY_EFI "$efi_dev"
  disk_step "mounting the ESP" mount "$efi_dev" /mnt"$esp_mount_in_target"

  # The orchestrator's first act is to verify this handoff. Check it here so
  # a failure names the step that broke rather than surfacing later as
  # "protected mode: /mnt is not a mountpoint".
  mountpoint -q /mnt ||
    _disk_abort "Target /mnt is not mounted; not starting the installer"
  mountpoint -q "/mnt$esp_mount_in_target" ||
    _disk_abort "ESP is not mounted at /mnt$esp_mount_in_target"
}
