#!/bin/bash
# Exercise the shipped service, both format callers, missing/malformed-state
# fallbacks, actual keyslot costs and repeated unlocks in a 4 GiB live guest.
# Standalone: OMARCHY_INTEGRATION_ISO=/path/to.iso bash test/integration.d/luks-calibration-test.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

[[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
qemu-img create -f qcow2 "$RUN_DIR/scratch.qcow2" 1G >/dev/null
cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
MEMORY=4096 start_vm "$RUN_DIR/scratch.qcow2" "$RUN_DIR/serial.log" \
  -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
  -device ide-cd,drive=cdrom0,bootindex=2
bootstrap_live_root_ssh
# No cidata is attached: the wizard is waiting while the boot job runs.
ssh_live_root 'timeout 120 bash -c "until test -f /run/omarchy-luks-calibration/result.json; do sleep 1; done"'
ssh_live_root 'journalctl -b -u omarchy-luks-calibrate.service --no-pager' >"$RUN_DIR/calibration-unit.log"
ssh_live_root 'cat >/tmp/luks-calibration-guest.py' <"$ROOT/test/luks-calibration-guest.py"
if ssh_live_root 'python /tmp/luks-calibration-guest.py' >"$RUN_DIR/calibration.json" 2>"$RUN_DIR/calibration.stderr"; then
  check "both callers use measured costs; fallbacks unlock at comparable cost" true
else
  cat "$RUN_DIR/calibration.stderr" >&2
  check "both callers use measured costs; fallbacks unlock at comparable cost" false
fi
stop_vm
finish
