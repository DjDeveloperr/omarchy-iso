#!/bin/bash
#
# Try Omarchy: the boot menu's Try entry must bring up the real desktop from
# the medium, with pacman usable, and leave the machine's disk untouched.
#
# The ISO boots alone with a disk of random bytes for the machine's own; Try
# is picked in GRUB and the desktop waited for. A terminal there fetches a
# bootstrap that authorizes the harness's key and starts sshd, and the rest
# is checked over SSH. Runs on the default variant only: Try boots the ISO,
# which no install variant changes.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

if [[ ${VARIANT:-default} != default ]]; then
  log "Try Omarchy runs on the default variant only; skipping for ${VARIANT:-default}"
  exit 0
fi

# GRUB waits 3 s; wait_for_screen polls every 3 s and can miss it.
pick_try() {
  local tries=0
  until ocr_screen_once | grep -q "Try Omarchy"; do
    vm_running && ((tries++ < 600)) || return 1
  done
  press down
  capture_console "success-try-menu"
  press ret
}

# In the session's environment, for hyprctl.
try_ssh() {
  ssh_guest "export XDG_RUNTIME_DIR=/run/user/\$(id -u) \
    HYPRLAND_INSTANCE_SIGNATURE=\$(ls -t /run/user/\$(id -u)/hypr | head -1); $1" </dev/null
}

[[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
disk="$RUN_DIR/machine.qcow2"
head -c $((64 << 20)) /dev/urandom >"$RUN_DIR/machine.raw"
qemu-img convert -f raw -O qcow2 "$RUN_DIR/machine.raw" "$disk"
rm "$RUN_DIR/machine.raw"
cp "$disk" "$RUN_DIR/machine-pristine.qcow2"
if [[ $FIRMWARE == uefi ]]; then
  cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
  ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
fi

log "Booting the ISO alone and picking Try Omarchy"
start_vm "$disk" "$RUN_DIR/serial.log" \
  -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
  -device ide-cd,drive=cdrom0,bootindex=2
check "GRUB offers Try Omarchy within its countdown" pick_try
# Omarchy's first-login notifications: any of them is the desktop.
check "Try Omarchy reaches the desktop" wait_for_screen "Keybindings\|Setup Git\|Update System" 300
capture_console "success-try-desktop"

mkdir -p "$BASE_DIR/www"
cat >"$BASE_DIR/www/bootstrap-try" <<EOF
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "$(cat "$SSH_KEY.pub")" >>~/.ssh/authorized_keys
sudo systemctl start sshd.service
EOF
(cd "$BASE_DIR/www" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
HTTP_PID=$!
press meta_l-ret
sleep 4
type_text "curl -fsS http://10.0.2.2:$HTTP_PORT/bootstrap-try -o /tmp/bs && bash /tmp/bs"
press ret
check "the Try session answers SSH" wait_for_ssh 120 failure-try-ssh

check "the root is the Try overlay" try_ssh '[ "$(findmnt -no FSTYPE,SOURCE /)" = "overlay omarchy-try" ]'
check "no unit failed" try_ssh 'systemctl is-system-running --wait >/dev/null; ! systemctl --failed --no-legend | grep -q .'
check "Hyprland runs with a monitor" try_ssh "hyprctl -j monitors | jq -e 'length > 0'"
check "the Omarchy shell runs" try_ssh "pgrep -x quickshell"
check "nothing on the machine's disk is mounted" try_ssh '! lsblk -nro MOUNTPOINTS /dev/vda | grep -q .'
check "the session made its own pacman keyring" try_ssh '[ "$(systemctl show -p Result --value omarchy-try-keyring)" = success ]'
check "pacman installs a package" try_ssh "sudo pacman -S --noconfirm --needed cowsay >/dev/null && cowsay try"

stop_vm
check "the machine's disk is unchanged" qemu-img compare -q "$RUN_DIR/machine-pristine.qcow2" "$disk"
finish
