# Recording the installer in Danish (handoff)

Goal: a video of every step of the ISO installer when picking Danish, from the greeter through the first login, for the installer-language work (omarchy branch `installer-language`, this repo's branch `fifty-languages`).

## Build the ISO

Needs Docker (the build runs it through `sudo`, so run this in a terminal), and checkouts of omarchy at `installer-language` and omarchy-pkgs side by side:

```bash
./bin/omarchy-iso-make --no-cache --keep-pkg-cache --no-boot-offer --local-source ../omarchy ../omarchy-pkgs
```

`--no-cache` matters on a machine that built ISOs before: a stale offline-repo cache in `~/.cache/omarchy/iso_*` made pacman reject the freshly built `omarchy-settings-dev` as "corrupted". `--keep-pkg-cache` skips purging the host pacman cache (needs sudo). Output: `release/omarchy-<date>-x86_64-local.iso` (about 6 GB).

## Record

Needs `qemu-desktop`, `edk2-ovmf`, `tesseract`, `tesseract-data-eng`, `imagemagick`, `ffmpeg`, and `/dev/kvm`:

```bash
python3 plans/record-installer-danish.py release/omarchy-*-local.iso /tmp/danish-run
```

It boots the ISO headless (QMP, no window), saves a frame every 0.25s (every 3s during the install, as a time-lapse), and drives the installer by OCR: greeter → language (Dansk is the 10th row) → keyboard (Danish preselected) → username `dhh`, password `omarchy`, name, email (skipped: on the Danish keymap `@` is AltGr+2), hostname, timezone → review → disk → install mode → overwrite warning (Ctrl+C for unencrypted) → install dashboard → reboot → SDDM login → Omarchy menu (Super+Space) and keybindings (Super+K). Then make the video:

```bash
ffmpeg -framerate 4 -pattern_type glob -i '/tmp/danish-run/frames/*.ppm' -vf "scale=1280:-2,format=yuv420p" -c:v libx264 installer-danish.mp4
```

## Known issue from the first run

Every installer step went through in Danish, but the "install finished" wait (`Genstart nu|installeret`) matched after 77 seconds — too fast for a real install, so it probably matched other text (perhaps a failure screen) and rebooted early. Look at the frames around the start of the time-lapse, tighten that wait (e.g. wait for `Genstart nu` alone, or for the dashboard's finish screen), and rerun.
