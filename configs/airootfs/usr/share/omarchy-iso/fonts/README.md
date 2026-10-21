# Live console fonts

`omarchy-live16.psf.gz` (8x16) and `omarchy-live32.psf.gz` (16x32) are the
live ISO's console fonts. `.automated_script.sh` loads the one matching the
height the kernel picked for the screen.

They are Debian's Terminus subsets for Latin, Cyrillic and Greek
(`Uni2-Terminus16` and `Uni2-Terminus32x16`), which draw Cyrillic в and д in
the Russian form, with two glyphs swapped: ⌠ (U+2320) and ⌡ (U+2321) give way
to ▀ (U+2580) and ▄ (U+2584), taken from Terminus's IBM-437 fonts (`ter-i16n`,
`ter-i32n`), because the Omarchy logo is drawn with ▀ ▄ █. A console font holds
at most 512 glyphs and the Uni2 fonts use all of them; Terminus's own 512-glyph
`ter-v` fonts dropped the half blocks in 4.28 and draw в and д in the
Bulgarian form.

Rebuild, byte for byte:

```
psf-swap.py Uni2-Terminus32x16.psf.gz ter-i32n.psf.gz omarchy-live32.psf.gz 2320=2580 2321=2584
psf-swap.py Uni2-Terminus16.psf.gz ter-i16n.psf.gz omarchy-live16.psf.gz 2320=2580 2321=2584
```

| Input | From | sha256 |
|---|---|---|
| `Uni2-Terminus32x16.psf.gz` | Debian `console-setup-linux` 1.242~deb13u1 | `223d2ef308818682a664a8f640e319c9328a16f7db647d47576f9788579a8ac3` |
| `Uni2-Terminus16.psf.gz` | Debian `console-setup-linux` 1.242~deb13u1 | `76b38323e80e09cd44a4ca4b0eaa681101874f208b8b5ba00c8c594cfd3b91c2` |
| `ter-i32n.psf.gz` | Arch `terminus-font` 4.49.1-8 | `af90edc80f357f3c3a49a5505f43efa188c79ac09fad3e4cb4ec236072c7e6b3` |
| `ter-i16n.psf.gz` | Arch `terminus-font` 4.49.1-8 | `81b0462cf3173d718cc0b79b96ad3a39b32d3e4268edf88ee62869fe998bfe28` |

Outputs: `omarchy-live32.psf.gz` `086fb5b1273022325dfe229e914641f89d2966d32cae37b91e218ec26f7c97df`,
`omarchy-live16.psf.gz` `fa6eec0b86ec7e06217faa6ffc58a874c9835a07b93836f4c35cc3f208b53268`.
The rewritten unicode table keeps single code points and drops PSF2 sequence
entries, which the console does not use.

Terminus Font is © Dimitar Toshkov Zhekov under the SIL Open Font License 1.1
(`OFL.txt`), with Reserved Font Name "Terminus Font", so these modified fonts
carry their own names.
