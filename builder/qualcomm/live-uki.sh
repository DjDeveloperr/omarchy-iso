#!/usr/bin/env bash
#
# Runs inside the live image of an aarch64 build, once the live kernel and
# initramfs exist, with the kernel package's name. Snapdragon laptops get no
# device tree from their firmware, so the live system boots a UKI that carries
# one for every supported laptop, and systemd-stub picks by the machine's SMBIOS
# data. On a machine it has no device tree for, the stub leaves the firmware's
# own tables alone.
set -euo pipefail

kernel=/boot/vmlinuz-$1
initrd=/boot/initramfs-$1.img
uki=/boot/omarchy-live.efi
hwids=/usr/lib/systemd/boot/hwids/aa64

# Include supported Snapdragon generations while staying below the UKI section limit.
# EL2 variants share hardware IDs with their base DTBs and would be ambiguous.
shopt -s nullglob
dtbs=()
for dtb in /boot/dtbs/qcom/x1*.dtb /boot/dtbs/qcom/hamoa*.dtb \
           /boot/dtbs/qcom/glymur*.dtb /boot/dtbs/qcom/sc8280xp*.dtb; do
  [[ $dtb == *-el2.dtb ]] && continue
  dtbs+=("$dtb")
done
if (( ${#dtbs[@]} == 0 )); then
  echo "live-uki: $1 ships no Windows-on-ARM device trees under /boot/dtbs/qcom; this image will not boot a Snapdragon laptop"
  exit 0
fi

for f in "$kernel" "$initrd"; do
  if [[ ! -s $f ]]; then
    echo "live-uki: $f is missing; the live kernel setup should have produced it" >&2
    exit 1
  fi
done
if ! command -v ukify >/dev/null; then
  echo "live-uki: ukify not found; is systemd-ukify among the live packages?" >&2
  exit 1
fi
if [[ ! -d $hwids ]]; then
  echo "live-uki: no SMBIOS-ID database at $hwids (systemd >= 260 ships it)" >&2
  exit 1
fi

# Reserve room for the UKI's non-DTB sections.
if (( ${#dtbs[@]} > 90 )); then
  echo "live-uki: ${#dtbs[@]} device trees exceed the UKI section budget; narrow the prefixes" >&2
  exit 1
fi

args=()
for dtb in "${dtbs[@]}"; do
  args+=("--devicetree-auto=$dtb")
done

echo "live-uki: wrapping $kernel and $initrd with ${#dtbs[@]} device trees"
ukify build \
  --linux="$kernel" \
  --initrd="$initrd" \
  --hwids="$hwids" \
  "${args[@]}" \
  --output="$uki"

# Verify that ukify embedded every required section.
sections="$(ukify inspect "$uki")"
n_dtb="$(grep -c '^\.dtbauto:' <<<"$sections" || true)"
if ! grep -q '^\.hwids:' <<<"$sections"; then
  echo "live-uki: $uki has no .hwids section" >&2
  exit 1
fi
if (( n_dtb != ${#dtbs[@]} )); then
  echo "live-uki: $uki has $n_dtb .dtbauto sections, expected ${#dtbs[@]}" >&2
  exit 1
fi
echo "live-uki: $uki: $(stat -c %s "$uki") bytes, $n_dtb .dtbauto sections, .hwids present"
