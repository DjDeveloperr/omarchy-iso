#!/bin/bash
#
# Ventoy's normal mode boots a UEFI machine into this ISO's own GRUB, but first
# it reads every .cfg under /boot/grub on the ISO as text, collects the path on
# each line that starts with initrd, and appends its hook to those files. The
# hook is what shows the ISO, a file on the stick's data partition, to the live
# system as a disk. Ventoy drops any path with a $ in it
# (ventoy_grub_cfg_initrd_collect in ventoy_linux.c), so an entry that boots
# initramfs-${live_kernel}.img gets no hook: archiso never finds its medium
# and drops to a rescue shell behind the splash, which looks like a hang on
# the logo (omacom/omarchy#1814).
#
# So each GRUB config must name every live initramfs in full: the one for
# %KERNEL% and the one for linux-t2, which GRUB boots on a Mac.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

fail=0
for cfg in configs/grub/grub.cfg configs/grub/loopback.cfg; do
  paths=$(sed -nE 's/^[[:space:]]*initrd[^[:space:]]*[[:space:]]+//p' "$cfg" | tr -s ' \t' '\n\n')

  if grep -q '\$' <<<"$paths"; then
    echo "$cfg: initrd path with a variable, which Ventoy's normal mode skips: $(grep '\$' <<<"$paths" | head -1)"
    fail=1
  fi

  for initramfs in initramfs-%KERNEL%.img initramfs-linux-t2.img; do
    if ! grep -Fqx "/%INSTALL_DIR%/boot/%ARCH%/$initramfs" <<<"$paths"; then
      echo "$cfg: no initrd line names /%INSTALL_DIR%/boot/%ARCH%/$initramfs in full"
      fail=1
    fi
  done
done

[ "$fail" -eq 0 ] && echo "ok: the GRUB configs name every live initramfs in full for Ventoy"
exit "$fail"
