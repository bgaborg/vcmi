#!/usr/bin/env python3
"""Extracts animations (.def) and pictures (.pcx) from the Heroes 3 data on the PC, for local renders of the Quest host
(quest/tools/render-room.sh) without the headset. The output is the player's own game art: it goes to quest/out/h3/
(not in git) and must not be committed.

Usage: h3-extract.py NAME [NAME...]      (e.g. CPKMAN.def CmBkGrMt.pcx; case does not matter)
       H3_DATA=<the game's Data folder>  (default: the GOG install on C:)

An animation becomes quest/out/h3/<NAME>/<group>_<frame>.png (cropped, shadow in the alpha) and frames.json:
{"frames": [{"group", "frame", "left", "top", "full_size": [w, h], "file"}]}, the layout of VcmiData.decode_animation.
A picture becomes quest/out/h3/<NAME>.png.
"""

import json
import os
import struct
import sys
import zlib
from pathlib import Path

from PIL import Image

DATA = Path(os.environ.get("H3_DATA", r"C:\GOG Games\Heroes of Might and Magic 3 Complete\Data"))
OUT = Path(__file__).resolve().parent.parent / "out" / "h3"
LODS = ["H3ab_spr.lod", "H3ab_bmp.lod", "H3sprite.lod", "H3bitmap.lod"]  # the expansion's files first, as the game
# the special palette entries of a creature or object animation: clear, and the shadow's edge and body
SPECIAL_ALPHA = {0: 0, 1: 64, 4: 128, 5: 0, 6: 128, 7: 64}


def lod_file(name):
    """the bytes of file `name` from the first archive that has it"""
    for lod in LODS:
        with open(DATA / lod, "rb") as archive:
            head = archive.read(92)
            if head[:4] != b"LOD\0":
                continue
            count = struct.unpack_from("<I", head, 8)[0]
            for entry in struct.iter_unpack("<16sIIII", archive.read(32 * count)):
                if entry[0].split(b"\0")[0].decode("latin1").lower() == name.lower():
                    archive.seek(entry[1])
                    return zlib.decompress(archive.read(entry[4])) if entry[4] else archive.read(entry[2])
    raise FileNotFoundError(name)


def runs(data, at, width, wide):
    """one line (or block) of `width` pixels of run-length data at `at`: (pixels, the offset after it)"""
    line = bytearray()
    while len(line) < width:
        if wide:  # format 1: a code byte and a length byte
            code, length = data[at], data[at + 1] + 1
            at += 2
            raw = code == 0xFF
        else:  # formats 2 and 3: both in one byte
            code, length = data[at] >> 5, (data[at] & 31) + 1
            at += 1
            raw = code == 7
        if raw:
            line += data[at:at + length]
            at += length
        else:
            line += bytes([code]) * length
    return line[:width], at


def frame_pixels(data, at):
    """a frame at offset `at` of a .def: (full width, full height, width, height, left, top, palette indices)"""
    _, form, full_w, full_h, width, height, left, top = struct.unpack_from("<IIIIIIii", data, at)
    base = at + 32
    pixels = bytearray()
    if form == 0:
        pixels = data[base:base + width * height]
    elif form == 1:
        for offset in struct.unpack_from(f"<{height}I", data, base):
            pixels += runs(data, base + offset, width, True)[0]
    elif form == 2:
        for offset in struct.unpack_from(f"<{height}H", data, base):
            pixels += runs(data, base + offset, width, False)[0]
    elif form == 3:
        blocks = (width + 31) // 32
        for y in range(height):
            line = bytearray()
            for offset in struct.unpack_from(f"<{blocks}H", data, base + 2 * blocks * y):
                line += runs(data, base + offset, min(32, width - len(line)), False)[0]
            pixels += line
    else:
        raise ValueError(f"unknown frame format {form}")
    return full_w, full_h, width, height, left, top, bytes(pixels)


def extract_def(name, data):
    out = OUT / name.upper().removesuffix(".DEF")
    out.mkdir(parents=True, exist_ok=True)
    groups = struct.unpack_from("<I", data, 12)[0]
    palette = [tuple(data[16 + 3 * i:19 + 3 * i]) + (SPECIAL_ALPHA.get(i, 255),) for i in range(256)]
    palette = [(0, 0, 0, colour[3]) if i in SPECIAL_ALPHA else colour for i, colour in enumerate(palette)]
    at = 16 + 768
    frames = []
    for _ in range(groups):
        group, count = struct.unpack_from("<II", data, at)
        offsets = struct.unpack_from(f"<{count}I", data, at + 16 + 13 * count)
        at += 16 + 17 * count
        for index, offset in enumerate(offsets):
            full_w, full_h, width, height, left, top, pixels = frame_pixels(data, offset)
            file = f"{group}_{index}.png"
            if width and height:
                image = Image.new("RGBA", (width, height))
                image.putdata([palette[p] for p in pixels])
                image.save(out / file)
            frames.append({"group": group, "frame": index, "left": left, "top": top, "full_size": [full_w, full_h],
                           "file": file if width and height else ""})
    (out / "frames.json").write_text(json.dumps({"frames": frames}))
    print(name, "->", out, len(frames), "frames")


def extract_pcx(name, data):
    size, width, height = struct.unpack_from("<III", data, 0)
    if size == width * height:
        image = Image.frombytes("P", (width, height), data[12:12 + size])
        image.putpalette(data[12 + size:12 + size + 768])
    else:
        image = Image.frombytes("RGB", (width, height), data[12:12 + size], "raw", "BGR")
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / (name.upper().removesuffix(".PCX") + ".png")
    image.convert("RGB").save(out)
    print(name, "->", out, width, "x", height)


for wanted in sys.argv[1:]:
    (extract_def if wanted.lower().endswith(".def") else extract_pcx)(wanted, lod_file(wanted))
