#!/usr/bin/env bash
# The live ISO must boot from a Ventoy stick, in both of Ventoy's modes,
# without waiting in its initramfs.
#
# Ventoy keeps the ISO as a file on its exFAT partition, maps it to
# /dev/mapper/ventoy from its own initramfs scripts, and boots the ISO's
# kernel with them injected: a path neither an optical drive nor a dd'ed
# stick takes. On 4.5.0rc2 the udev hook waited 30 s there for a by-uuid
# link that a dmsetup-made disk never gets, and without that delay losetup
# found no /dev/loop-control to load the loop module through, so archiso
# dropped to a shell behind the splash. The check is when PID 1 of the live
# root started: a few seconds after the kernel, not 30.
#
# The stick comes from bin/omarchy-iso-test-ventoy-disk, which needs root
# for its loop device and mount: CI makes it on the runner before the test
# container starts and passes it in as OMARCHY_INTEGRATION_VENTOY_DISK.
# Ventoy boots this way only under UEFI here. The cidata drive gives root
# SSH on the live system; the install it starts goes to /dev/vda, never the
# stick.

export OMARCHY_INTEGRATION_FIRMWARE=uefi

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

VENTOY_DISK="${OMARCHY_INTEGRATION_VENTOY_DISK:-$RUN_DIR/ventoy.img}"
# When the live root's PID 1 may start, in seconds after the kernel: the
# 30 s wait put it past 30.
MAX_INITRAMFS_SECONDS=15

boot_from_ventoy() {
  local mode="$1" disk="$RUN_DIR/scratch-$1.qcow2" started_us

  qemu-img create -f qcow2 "$disk" "${DISK_GB}G" >/dev/null
  cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS-$mode.4m.fd"
  ACTIVE_OVMF="$RUN_DIR/OVMF_VARS-$mode.4m.fd"

  log "Booting the ISO from a Ventoy stick in $mode mode"
  # snapshot=on: Ventoy writes nothing the next boot should see.
  start_vm "$disk" "$RUN_DIR/serial-$mode.log" \
    -device qemu-xhci,id=xhci \
    -drive "file=$VENTOY_DISK,format=raw,if=none,id=ventoy,snapshot=on" \
    -device usb-storage,bus=xhci.0,drive=ventoy,removable=on,bootindex=0 \
    -drive "file=$CIDATA_IMG,format=raw,if=none,id=cidata" \
    -device usb-storage,bus=xhci.0,drive=cidata \
    "${LIVE_CIDATA_SMBIOS[@]}"

  # Ventoy's list holds the one ISO, selected. r switches to GRUB2 mode;
  # Enter boots, with no second menu (bin/omarchy-iso-test-ventoy-disk).
  check "Ventoy lists the ISO ($mode)" wait_for_screen "ventoy.net" 120
  [[ $mode == grub2 ]] && press r && sleep 1
  press ret

  if wait_for_live_root_ssh 300; then
    started_us=$(ssh_live_root "systemctl show -p UserspaceTimestampMonotonic --value" 2>/dev/null | tr -d '\r')
    log "Live root's PID 1 started ${started_us:-?} µs after the kernel ($mode mode)"
    check "the live initramfs found the Ventoy medium within ${MAX_INITRAMFS_SECONDS} s in $mode mode (PID 1 at ${started_us:-?} µs)" \
      test "${started_us:-999999999}" -lt $((MAX_INITRAMFS_SECONDS * 1000000))
  else
    check "the live ISO boots from Ventoy in $mode mode" false
  fi
  capture_console "ventoy-$mode"
  stop_vm
}

[[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
detect_packages
build_cidata

if [[ ! -f $VENTOY_DISK ]]; then
  log "Making a Ventoy stick with ${ISO##*/}"
  "$ROOT/bin/omarchy-iso-test-ventoy-disk" "$ISO" "$VENTOY_DISK"
fi

boot_from_ventoy normal
boot_from_ventoy grub2
# A stick made here holds a copy of the ISO; one passed in is the caller's.
[[ -n ${OMARCHY_INTEGRATION_VENTOY_DISK:-} ]] || rm -f "$VENTOY_DISK"
finish
