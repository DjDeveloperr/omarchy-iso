#!/bin/bash
#
# bin/omarchy-iso-test without a VM: its functions are taken out of the
# script and run against stubs for QEMU, QMP and OCR, so what the harness
# decides from what it sees can be checked here.

# shellcheck disable=SC2034 # the variables are read by the functions taken out of the harness

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
harness="$ROOT/bin/omarchy-iso-test"
bash -n "$harness"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The harness is a script that starts a VM when it is run; take only the
# functions under test.
take() {
  local name
  for name; do
    eval "$(sed -n "/^$name() {\$/,/^}\$/p" "$harness")"
    declare -F "$name" >/dev/null || fail "the harness no longer has $name"
  done
}

# ------------------------------------------------- --no-network first boot
#
# With no NIC there is no SSH to wait for, so an offline install passes on
# what the screen shows. It must not pass on the Reboot Now press alone: the
# installed system has to come up to its own console login.

take install_phase wait_for_first_boot_login
GUEST_HOSTNAME="omarchy-test"
SSH_KEY="$work/id_ed25519"
BASE_DISK="$work/base.qcow2"
BASE_OVMF="$work/OVMF_VARS.fd"
OVMF_VARS_TEMPLATE="$work/OVMF_VARS.template"
RUN_DIR="$work"
ISO="$work/omarchy.iso"
BOOT_TIMEOUT=60
FREE_SPACE=false PROVISION=false ENCRYPT=false NO_NETWORK=true
touch "$SSH_KEY" "$OVMF_VARS_TEMPLATE"

log() { :; }
qemu-img() { :; }
start_vm() { :; }
drive_configurator() { :; }
wait_for_install() { :; } # pressed Reboot Now and returned, as it does
bootstrap_ssh() { fail "bootstrap_ssh needs a network"; }
vm_running() { true; }
press() { :; }
sleep() { :; }
captured=()
capture_console() { captured+=("$1"); }
# The scripted screens in order, the last one forever. OCR runs in a
# pipeline's subshell, so where it is in the script is kept in a file.
screens() { printf '%s\n' "$@" >"$work/screens"; echo 1 >"$work/screen"; }
ocr_screen() {
  local n
  n=$(<"$work/screen")
  sed -n "${n}p" "$work/screens"
  (( n < $(wc -l <"$work/screens") )) && echo $((n + 1)) >"$work/screen"
  return 0
}

# The harness runs install_phase under set -e, outside any condition, so a
# failing step ends it there. Run it the same way: an `if` around it would
# switch set -e off inside and hide the failure.
offline_install() {
  set +e
  (set -e; install_phase; printf '%s\n' "${captured[@]}" >"$work/captured") 2>"$work/err"
  installed=$?
  set -e
}

screens "" "archiso login:"
offline_install
((installed != 0)) || fail "an offline install passed without the installed system reaching a login"

screens "Rebooting" "" "Arch Linux 6.17 (tty3)" "omarchy-test login:"
offline_install
((installed == 0)) || fail "an offline install that reached its login failed: $(cat "$work/err")"
grep -qx "success-first-boot-no-network" "$work/captured" ||
  fail "the offline install did not record its first boot"

echo "ok - an offline install passes only once the installed system reaches its login"

