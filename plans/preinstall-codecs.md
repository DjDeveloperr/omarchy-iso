# Preinstall Codecs Plan: Ship Clean, Opt In At First Boot

## Goal

Let a hardware partner sell machines with Omarchy preinstalled without the unit shipping patent-encumbered codecs (H.264/AVC, H.265/HEVC, AAC), and give the new owner a one-click, explicit opt-in to install them at first boot.

This is the model Fedora (codecs from RPM Fusion) and Ubuntu (the "third-party software and additional media formats" prompt) use. The preinstalled machine, as sold, contains no encumbered decoder or encoder. The owner fetches them afterwards, from Arch, by their own choice.

Downloadable Omarchy (the public ISO) is out of scope and keeps shipping the full codec set, as today.

This reduces patent exposure on preinstalled units; it does not eliminate it. Royalty and indemnity terms still belong in the OEM contract (see Open Questions).

## Current State (October 2026)

- The ISO writes a pre-built root image (`builder/build-root-image.sh`) pacstrapped from the package lists in the omarchy package (`install/omarchy-base.packages`, `install/omarchy-other.packages`), plus `builder/image.packages`. Per-machine packages come from the offline mirror bundled at `/var/cache/omarchy/mirror/offline`.
- Deferred provisioning (`defer_provisioning` in `orchestrator/context.py`, or a `defer-provisioning` marker) installs the whole system and creates the user at first boot. `create_factory_snapshot` snapshots the result, and `omarchy-system-factory-reset` returns a machine to it. That is the preinstall path today; nothing in it touches codecs.
- First login runs `omarchy-provision-first-run`, which sends ordered notifications (`install/user/first-run/*.sh`, `omarchy-notification-send ... --exec`). The fingerprint invitation hook is the pattern to copy.
- Installed systems and the ISO get `[core]`/`[extra]` from **Omarchy's own Arch mirror** (`stable-mirror.omarchy.org`), not Arch's. A codec download "from the configured mirror" is therefore Omarchy distributing it. This matters for the opt-in design below.
- `manifests/fresh-4.json` pins the installed package set, including `ffmpeg`, `mesa`, `x264` and `x265`.

### Where the encumbered codecs live today

Checked on a stock install (ffmpeg 2:9.0.2-2, mesa, Qt 6.12):

| Package | Encumbered content | Pulled in by |
| --- | --- | --- |
| `ffmpeg` | H.264/HEVC/AAC decoders; `--enable-gpl` with x264, x265 | base list; 20+ dependents incl. hype, monologue, omacut, omareel, strata (via gst-libav), mpv, gpu-screen-recorder, obs-studio, chromium, qt6-webengine, qt6-multimedia-ffmpeg |
| `x264`, `x265` | H.264/HEVC encoders | ffmpeg, libheif |
| `libde265` | HEVC decoder | libheif |
| `libheif` | HEIC (HEVC) images via x265/libde265 | image stack |
| `openh264` | H.264 codec (Arch builds from source, so Cisco's royalty coverage does **not** apply) | chromium, qt6-webengine, libheif |
| `libfdk-aac` | AAC (Fraunhofer license grants no patent rights) | pipewire-audio (Bluetooth A2DP AAC) |
| `mesa`, `vulkan-radeon`, `vulkan-intel` | VA-API / Vulkan Video H.264/HEVC decode and encode | base lists |
| `intel-media-driver`, `libva-intel-driver` | Intel hardware H.264/HEVC | `omarchy-other.packages` |
| `libva-nvidia-driver` | NVDEC bridge (codec lives in NVIDIA's driver) | `omarchy-other.packages` |

Unencumbered and kept: AV1 (dav1d, svt-av1, aom), VP8/VP9 (libvpx), Opus, Vorbis, FLAC, MP3 (patents expired 2017).

Hardware decode is not covered by the GPU vendor: the pools license the end product, which is why Dell and HP disable HEVC hardware decode on some SKUs. The mesa and Intel driver rows are in scope for that reason.

## Core Architecture

```text
Preinstall image (built with --preinstall)
  -> "-free" package variants from [omarchy], same sonames, provides= the full names
  -> no x264 / x265 / libde265 / libfdk-aac / openh264 / intel-media-driver on disk
  -> /etc/omarchy/codecs = free
  -> factory snapshot taken in this state

First login
  -> notification: "Install additional media codecs (H.264, HEVC, AAC)?"
  -> omarchy-codecs-install
       -> fetch full packages from Arch's own archive, pinned to the system's snapshot date
       -> swap -free variants for the full ones in one pacman transaction
       -> /etc/omarchy/codecs = full

Afterwards
  -> normal omarchy-update from Omarchy's mirror (today's status quo for every Omarchy user)
```

Factory reset returns to the free snapshot, so the next owner gets the prompt again.

## Decisions

### Free variants are new package names, not overrides

`[omarchy]` sits first in every pacman.conf, so a codec-stripped package named `ffmpeg` there would downgrade every Omarchy user. Instead, ship `ffmpeg-free`, `mesa-free`, etc. with:

- `provides=("ffmpeg=$pkgver-$pkgrel" "libavcodec.so=63-64" ...)` mirroring Arch's `provides` exactly, sonames included, so every dependent resolves without a rebuild.
- `conflicts=(ffmpeg)`, and **no** `replaces`: pacman never swaps a `-free` package out on `-Syu`, and never swaps one in on a normal system.

Nobody gets a `-free` package unless the preinstall build or a deliberate `pacman -S` asks for it.

### Track Arch in lockstep, from the same snapshot

A `-free` package that lags Arch's soname breaks `-Syu` for preinstalled machines that have not opted in. omarchy-pkgs already runs tracking bots (`auto/track-branches-*`); add one that rebuilds each `-free` package whenever the stable mirror's snapshot carries a new upstream version, built against that snapshot, with the same `pkgver`/epoch and `pkgrel` + `.1`.

CI fails the stable mirror promotion if a `-free` package's version lags its upstream package on that snapshot.

### Avoid rebuilding Chromium and QtWebEngine

Both depend on system ffmpeg and on `libopenh264.so`. If they decode H.264 only through system libavcodec, `ffmpeg-free` strips it with no rebuild, and an `openh264-stub` package (Fedora's `noopenh264`: provides `openh264` and `libopenh264.so`, encodes nothing) satisfies the link. **Verify** with Arch's chromium build flags and a playback test before relying on it; a full Chromium rebuild per release is not an acceptable maintenance cost.

### Opt-in downloads come from Arch, not Omarchy

The point of the opt-in is that a third party distributes the codecs to a user who asked for them. Since Omarchy mirrors Arch, `omarchy-codecs-install` must not use the system's configured `[core]`/`[extra]`. It uses a dedicated pacman config pointing at the Arch Linux Archive (`archive.archlinux.org/repos/YYYY/MM/DD/`) pinned to the snapshot date of the system's current mirror state, so the full packages match the installed libraries exactly (no partial upgrade).

After the swap, ordinary updates come from Omarchy's mirror like any Omarchy install. That is the existing exposure of the public ISO, unchanged by this plan.

### Hardware decode on the free image

- AMD/Intel via mesa: build `mesa-free` (and its `vulkan-radeon-free`, `vulkan-intel-free` split packages) with `-Dvideo-codecs=` limited to AV1/VP9, the way Fedora builds mesa. VP9/AV1 hardware decode keeps working, so YouTube stays efficient.
- Intel media driver: leave `intel-media-driver` and `libva-intel-driver` off the free image and install them in the opt-in. If the battery cost of losing Intel VA-API for VP9/AV1 is too high, build `intel-media-driver-free` with HEVC/AVC disabled instead (verify the driver's per-codec CMake switches).
- NVIDIA: `libva-nvidia-driver` is a thin bridge; the codec implementation is NVIDIA's driver. Leave it in, and settle coverage with the partner (Open Questions). Launch partners are expected to be Intel/AMD.

### Bluetooth AAC

Rebuild pipewire with `-Dbluez5-codec-aac=disabled` and ship `pipewire-audio-free`. A2DP falls back to SBC/SBC-XQ/LDAC/aptX where available; AirPods-class headphones lose AAC until opt-in. (A `libfdk-aac` stub that makes only the AAC plugin fail to load is the cheaper alternative; prefer the rebuild for clarity.)

### HEIC images

Ship `libheif-free` built without the x265/libde265/openh264 plugins. AVIF keeps working; HEIC photos from iPhones need the opt-in.

## Package Set

New in omarchy-pkgs (`pkgbuilds/<name>-free/`, each a delta on Arch's PKGBUILD):

| Package | Change from Arch |
| --- | --- |
| `ffmpeg-free` | drop `--enable-gpl` and x264/x265; `--disable-decoder=h264,hevc,aac,aac_latm,...` and matching parsers/encoders (copy Fedora's `ffmpeg-free` enable list rather than a deny list) |
| `mesa-free` + `vulkan-radeon-free`, `vulkan-intel-free` (+ `vulkan-asahi-free` on aarch64) | `-Dvideo-codecs=av1dec,av1enc,vp9dec` |
| `libheif-free` | no HEVC/H.264 plugins |
| `pipewire-audio-free` | no fdk-aac Bluetooth codec |
| `openh264-stub` | provides `openh264`, `libopenh264.so`; no codec |

Dropped from the free image entirely: `x264`, `x265`, `libde265`, `libfdk-aac`, `openh264`, `intel-media-driver`, `libva-intel-driver`.

Unchanged, and free automatically through `ffmpeg-free`: gst-libav, mpv, gpu-screen-recorder, obs-studio, ffmpegthumbnailer, qt6-multimedia-ffmpeg, and Omarchy's own apps.

## File Changes

### omarchy-pkgs

- `pkgbuilds/{ffmpeg,mesa,libheif,pipewire}-free/`, `pkgbuilds/openh264-stub/`.
- A tracking job that rebuilds each `-free` package on every upstream bump in the stable snapshot, and a promotion gate that fails on version lag.
- A test that installs each `-free` package in place of its upstream one in a clean container and runs `pacman -Dk` plus a `ldd` scan of every dependent.

### omarchy (the OS package)

- `install/omarchy-preinstall-substitutions` — the single source of truth: `ffmpeg ffmpeg-free`, `mesa mesa-free`, …, and `x264 -` for removals. Read by the ISO build and by `omarchy-codecs-install` (in reverse).
- `bin/omarchy-codecs-install` — writes the Arch Archive pacman config for the current snapshot date, runs one `pacman -S` transaction swapping every `-free` package for its full name and adding the dropped packages, then writes `/etc/omarchy/codecs = full`. No-op when already `full`.
- `bin/omarchy-codecs-status` — prints `free` or `full`; used by the hook, the menu and tests.
- `install/user/first-run/codecs.sh` — step in `omarchy-provision-first-run`, sent after the welcome notification, only when `omarchy-codecs-status` says `free`. Modeled on `setup-fingerprint.hook`: `omarchy-notification-send -g <icon> "$(omarchy-i18n firstRun.codecsTitle)" "$(omarchy-i18n firstRun.codecsBody)" --exec omarchy-launch-floating-terminal-with-presentation omarchy-codecs-install`. Neutral wording: what it installs, that it downloads from Arch Linux, nothing more.
- An Omarchy menu entry under Install for the same command, so a dismissed toast is not a dead end.
- i18n keys `firstRun.codecsTitle`, `firstRun.codecsBody` in every language file.
- `bin/omarchy-capture-screenrecording` — on a free system:
  - pass `-k av1` (or `vp9` where the GPU has no AV1 encoder) instead of `-k auto`, and drop `-fallback-cpu-encoding` to a codec ffmpeg-free can encode (`libsvtav1`/`libvpx-vp9`);
  - trim re-encode (line ~529, `libx264`) switches to `libsvtav1` and a `.webm`/`.mkv` container.
  
  Check the codec status once; the full system keeps today's H.264 defaults.
- Omarchy apps (Hype, Monologue, Omacut, Omareel, Strata): audit export and default-encode paths for `libx264`/`aac`; fall back to AV1/VP9 + Opus when `avcodec_find_encoder` returns null, and show a "Install codecs" hint when an import fails to find a decoder.

### omarchy-iso

- `bin/omarchy-iso-make --preinstall` → `OMARCHY_FLAVOR=preinstall` into `builder/build-iso.sh`.
- `builder/build-iso.sh` — when `OMARCHY_FLAVOR=preinstall`, apply `omarchy-preinstall-substitutions` to the merged package list before it goes to `build-root-image.sh` and into the offline mirror.
- `builder/prune-offline-mirror.sh` — in preinstall builds, remove every substituted and dropped package from the offline mirror. The disk and the ISO must not carry them at all, not just leave them uninstalled.
- Orchestrator: a `preinstall` flag (configurator option and autoinstall marker, alongside `defer-provisioning`) that writes `/etc/omarchy/codecs = free` before `create_factory_snapshot`.
- `manifests/preinstall-4.json` — the preinstall expected-state manifest, generated the same way as `fresh-4.json`.
- `test/integration.d/preinstall-codecs-test.sh` (see Validation).

## Validation

Automated, on every preinstall build:

1. **Image audit.** In the built root image and the offline mirror: none of `x264 x265 libde265 libfdk-aac openh264 intel-media-driver libva-intel-driver` and no upstream `ffmpeg`/`mesa`/`libheif`/`pipewire-audio` is present; `readelf -d` over `/usr` finds no `NEEDED` on `libx264`, `libx265`, `libde265`, `libfdk-aac`, `libopenh264` (other than the stub); `ffmpeg -decoders`/`-encoders` lists no `h264`, `hevc`, `aac`.
2. **Factory reset.** Extend the `factory-reset` scenario: after reset the system reports `free` and the first-run codec notification appears again.
3. **Opt-in.** In the VM, run `omarchy-codecs-install`; assert every download URL is `archive.archlinux.org`, the transaction succeeds, `pacman -Dk` is clean, status is `full`, and H.264/HEVC/AAC sample files decode.
4. **Update survival.** Free system, `omarchy-update` across a stable mirror bump: stays `free`, no partial-upgrade errors. Full system: updates as any Omarchy install.

Manual, on partner hardware before launch:

- YouTube in Chromium (VP9/AV1, hardware decode where available), Netflix/Widevine behavior, an H.264 MP4 in mpv (clean error, codec hint), screen recording and trim, Bluetooth headphones (SBC fallback), an iPhone HEIC photo (clean failure), then opt in and repeat.
- Battery drain on a 1-hour YouTube loop, free vs full, on each partner SKU.

## Rollout

1. **Packages.** `ffmpeg-free` and `openh264-stub` first; prove Chromium and QtWebEngine need no rebuild. Then `mesa-free`, `libheif-free`, `pipewire-audio-free`. Tracking and promotion gate before any of them reach stable.
2. **Opt-in tooling.** `omarchy-codecs-install`, status, substitutions file; tested by swapping on an ordinary install in a VM.
3. **App and recorder fallbacks.** Screen recording and Omarchy apps behave on a free system.
4. **ISO flavor.** `--preinstall`, offline mirror pruning, the marker, manifest, integration tests.
5. **First-run UX.** Notification, menu entry, i18n.
6. **Partner pilot** on the launch SKUs.

## Acceptance Criteria

- A `--preinstall` image, its offline mirror and its factory snapshot contain no package or library from the encumbered list.
- Every app in the base install launches and handles media on a free system; nothing crashes for lack of a codec.
- One notification at first login; one command installs the full set from Arch's archive in a single transaction.
- Free systems survive stable updates without intervention.
- Factory reset restores the free state and the prompt.
- The public ISO is byte-for-byte unaffected (no `-free` packages, no marker).

## Open Questions

- **OEM contract.** Does the partner already hold Via LA AVC/AAC and Access Advance HEVC licenses for these SKUs (most Windows OEMs do)? If yes, a partner may prefer to ship the full set under their license; this plan is then a fallback, not a requirement. Either way, get a written statement that the factory image is the free flavor, and an indemnity allocation.
- **NVIDIA.** Is NVDEC/NVENC covered for a Linux end product, or should `libva-nvidia-driver` also move into the opt-in?
- **Snapshot date.** Is `stable-mirror.omarchy.org` an exact copy of Arch at a recorded date, so the Arch Archive serves identical package versions? If it lags or mixes dates, the opt-in needs a different version-matching strategy.
- **Wording review.** Have counsel review the notification text and the fact that Omarchy's tool performs the download (the inducement question). Fedora and Ubuntu precedent is strong, but this should be a lawyer's sign-off, not ours.
- **Widevine/DRM streaming.** Does Netflix/Prime in Chromium rely on system H.264 or on Widevine's own decoder? Determines whether those services work before opt-in.
