#!/bin/bash
#
# test/integration.d/base-test.sh without a VM: its functions are taken out
# of the harness and run against stubs for QEMU, QMP, OCR and SSH, so what
# the harness decides from what it sees can be checked here.

# shellcheck disable=SC2034,SC2329 # the variables and stubs are used by the functions taken out of the harness

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
harness="$ROOT/test/integration.d/base-test.sh"
bash -n "$harness"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The harness is a script that starts a VM when it is read; take only the
# functions under test.
take() {
  local name
  for name; do
    eval "$(sed -n "/^$name() {\$/,/^}\$/p" "$harness")"
    declare -F "$name" >/dev/null || fail "the harness no longer has $name"
  done
}

# The scenarios run these under set -e, outside any condition, so a failing
# step ends the scenario there. Run them the same way: an `if` around one
# would switch set -e off inside it and hide that.
run() {
  set +e
  (set -e; "$@") >"$work/out" 2>&1
  status=$?
  set -e
}

log() { :; }
vm_running() { true; }
capture_console() { :; }
type_text() { :; }
press() { echo "$1" >>"$work/pressed"; }
# Time passes only in sleep, and is kept in a file because the functions
# run in a subshell. A loop that sleeps far past its budget is stopped here
# instead of hanging the test.
sleep() {
  local slept
  slept=$(($(<"$work/slept") + ${1%.*}))
  echo "$slept" >"$work/slept"
  ((slept <= 100000)) || { echo "still waiting after ${slept}s" >&2; exit 99; }
}
echo 0 >"$work/slept"

# ---------------------------------------------- console login on the next VT
#
# bootstrap_ssh logs in on tty3, then tty4, then tty5. When the VT switches
# before the password prompt shows, that attempt is lost, not the scenario.

take bootstrap_ssh
BASE_DIR="$work/base"
SSH_KEY="$work/id_ed25519"
HTTP_PORT=2323
GUEST_USER=omarchy GUEST_PASSWORD=omarchy
echo "ssh-ed25519 AAAA test" >"$SSH_KEY.pub"
mkdir -p "$work/bin"
printf '#!/bin/sh\nexit 0\n' >"$work/bin/python3" # the bootstrap's HTTP server
chmod +x "$work/bin/python3"
PATH="$work/bin:$PATH"
ocr_screen() { echo "omarchy-test login:"; }
# The first attempt's password prompt never shows; the second one's does.
wait_for_screen() { [[ $(grep ctrl-alt-f "$work/pressed" | tail -n1) != ctrl-alt-f3 ]]; }
wait_for_ssh() { true; }

: >"$work/pressed"
run bootstrap_ssh
((status == 0)) || fail "a lost password prompt on tty3 ended the scenario: $(cat "$work/out")"
grep -qx ctrl-alt-f4 "$work/pressed" || fail "the second attempt did not use tty4: $(paste -sd' ' "$work/pressed")"
echo "ok - a console login whose password prompt never shows is retried on the next VT"

# --------------------------------------- the install wait keeps to its budget
#
# An encrypted BIOS install whose Plymouth prompt is typed into blind, sample
# after sample, still times out after INSTALL_TIMEOUT, not later.

take wait_for_unattended_install
ENCRYPT=true
INSTALL_TIMEOUT=600
ssh_guest() { false; }
ocr_screen() { echo "OMARCHY"; } # the logo and nothing else, for ever

echo 0 >"$work/slept"
run wait_for_unattended_install install
slept=$(<"$work/slept")
((status == 1)) || fail "a boot stuck at the logo did not time out (status $status): $(tail -n3 "$work/out")"
grep -q "Timed out after ${INSTALL_TIMEOUT}s" "$work/out" || fail "no timeout message: $(tail -n3 "$work/out")"
((slept <= INSTALL_TIMEOUT + 10)) || fail "a ${INSTALL_TIMEOUT}s budget took ${slept}s"
echo "ok - typing the passphrase blind counts against the install timeout"
