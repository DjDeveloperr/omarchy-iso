# Appliance installs: an image built with omarchy-iso-make --appliance installs
# with no questions and leaves the machine waiting to be adopted over SSH by
# the computer whose key the image carries (omarchy device adopt). Sourced by
# the configurator after disk-partitioning.sh.

APPLIANCE_KEYS="${APPLIANCE_KEYS:-/usr/share/omarchy-iso/appliance/authorized_keys}"
APPLIANCE_PLATFORM_DETECTOR="${APPLIANCE_PLATFORM_DETECTOR:-/usr/share/omarchy-iso/omarchy-hw-platform}"
APPLIANCE_COUNTDOWN="${APPLIANCE_COUNTDOWN:-15}"

# The disk an appliance install erases: the first one the disk screen would
# offer, as long as it is internal. With only removable or USB disks left
# there is nothing an appliance should erase on its own.
appliance_disk() {
  local exclude=${1:-} disk removable tran
  disk=$(install_disk_candidates "$exclude" | head -n1)
  [[ -n $disk ]] || return 1
  read -r removable tran < <(lsblk -dno RM,TRAN "$disk" 2>/dev/null)
  if disk_is_external "$disk" "$removable" "$tran"; then
    return 1
  fi
  printf '%s\n' "$disk"
}

# The machine's name until it is adopted: spark-<last four hex digits of the
# onboard Ethernet address> on a GB10, as DGX OS names a DGX Spark, and
# omarchy-<same> elsewhere. Onboard means a PCI Ethernet port that is not a
# ConnectX fabric port (vendor 0x15b3); without one the Wi-Fi address stands in.
appliance_hostname() {
  local net=${SYSFS_NET:-/sys/class/net} prefix=omarchy iface address="" fallback=""
  if [[ $(appliance_platform) == "aarch64-gb10" ]]; then
    prefix=spark
  fi

  for iface in "$net"/*; do
    [[ -e $iface/device ]] || continue
    [[ $(basename "$(readlink -f "$iface/device/subsystem")") == "pci" ]] || continue
    [[ $(cat "$iface/address" 2>/dev/null) =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || continue
    if [[ -e $iface/wireless || -e $iface/phy80211 ]]; then
      [[ -n $fallback ]] || fallback=$(<"$iface/address")
      continue
    fi
    [[ $(cat "$iface/device/vendor" 2>/dev/null) == "0x15b3" ]] && continue
    address=$(<"$iface/address")
    break
  done

  address=${address:-$fallback}
  if [[ -z $address ]]; then
    address=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')
  fi
  address=${address//:/}
  printf '%s-%s\n' "$prefix" "${address: -4}"
}

appliance_platform() {
  [[ -f $APPLIANCE_PLATFORM_DETECTOR ]] || return 0
  /bin/bash -p "$APPLIANCE_PLATFORM_DETECTOR" 2>/dev/null || true
}

# Show the disk about to be erased and count down; any key cancels, and the
# caller falls back to the interactive installer. Booting the wrong machine
# from an appliance stick must never erase it without a chance to stop.
appliance_countdown() {
  local disk=$1 name=$2 seconds=$APPLIANCE_COUNTDOWN key pad=${PADDING_LEFT:-0}

  clear
  echo
  gum style --padding "0 0 0 $pad" --bold "$(t appliance.title)"
  echo
  gum style --padding "0 0 0 $pad" \
    "$(t appliance.erase "$(get_disk_info "$disk" | sed 's/[[:space:]]*$//')")" \
    "$(t appliance.adopt "$name")" \
    "" \
    "$(t appliance.cancel)"
  echo

  while ((seconds > 0)); do
    printf '\r%*s%s ' "$pad" "" "$(t appliance.countdown "$seconds")"
    if read -rsn1 -t 1 key </dev/tty 2>/dev/null; then
      printf '\n'
      return 1
    fi
    seconds=$((seconds - 1))
  done
  printf '\n'
}
