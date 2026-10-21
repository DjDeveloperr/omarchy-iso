#!/usr/bin/env python3
"""psf-swap.py BASE DONOR OUT OLD=NEW...: copy glyphs between console fonts.

For each OLD=NEW pair (hex codepoints), the glyph BASE draws for OLD is
replaced by the glyph DONOR draws for NEW, and the unicode table entry moves
from OLD to NEW. The font keeps its size and glyph count (the console caps
fonts at 512 glyphs), so it trades characters it doesn't need for ones it
does, the way Powerline's Terminus PSF does. Reads PSF1 and PSF2 and writes
OUT in BASE's format.
"""
import gzip
import struct
import sys

PSF2 = b"\x72\xb5\x4a\x86"
PSF1 = b"\x36\x04"


def load(path):
    data = gzip.open(path).read() if path.endswith(".gz") else open(path, "rb").read()
    if data[:4] == PSF2:
        hdr, flags, n, size, h, w = struct.unpack("<IIIIII", data[8:32])
        glyphs = [data[hdr + i * size: hdr + (i + 1) * size] for i in range(n)]
        table = [set(e.split(b"\xfe")[0].decode("utf-8", "ignore"))
                 for e in data[hdr + n * size:].split(b"\xff")[:n]]
        return {"fmt": 2, "header": data[:hdr], "dims": (w, h), "glyphs": glyphs, "table": table}
    if data[:2] == PSF1:
        mode, h = data[2], data[3]
        n = 512 if mode & 1 else 256
        glyphs = [data[4 + i * h: 4 + (i + 1) * h] for i in range(n)]
        raw, table, cur, seq = data[4 + n * h:], [], set(), False
        for i in range(0, len(raw) - 1, 2):
            v = raw[i] | raw[i + 1] << 8
            if v == 0xFFFF:
                table.append(cur)
                cur, seq = set(), False
            elif v == 0xFFFE:
                seq = True
            elif not seq:
                cur.add(chr(v))
        return {"fmt": 1, "mode": mode, "dims": (8, h), "glyphs": glyphs, "table": table[:n]}
    sys.exit(f"{path}: not a PSF font")


def save(font, path):
    g = b"".join(font["glyphs"])
    if font["fmt"] == 2:
        tab = b"".join("".join(sorted(e)).encode() + b"\xff" for e in font["table"])
        data = font["header"] + g + tab
    else:
        w, h = font["dims"]
        tab = b"".join(b"".join(struct.pack("<H", ord(c)) for c in sorted(e)) + b"\xff\xff"
                       for e in font["table"])
        data = PSF1 + bytes([font["mode"] | 2, h]) + g + tab
    with open(path, "wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as f:
        f.write(data)


def index_of(font, cp):
    for i, entry in enumerate(font["table"]):
        if chr(cp) in entry:
            return i
    sys.exit(f"U+{cp:04X} not in font")


base_path, donor_path, out_path, *pairs = sys.argv[1:]
base, donor = load(base_path), load(donor_path)
if base["dims"] != donor["dims"]:
    sys.exit(f"sizes differ: {base['dims']} vs {donor['dims']}")
for pair in pairs:
    old, new = (int(x, 16) for x in pair.split("="))
    i = index_of(base, old)
    base["glyphs"][i] = donor["glyphs"][index_of(donor, new)]
    base["table"][i] = {chr(new)}
save(base, out_path)
