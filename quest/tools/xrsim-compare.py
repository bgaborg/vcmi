#!/usr/bin/env python3
"""Compares the shots of a Meta XR Simulator run (quest/tools/xrsim.sh) with a baseline run's: a shot fails when more
than 2 % of its pixels differ by more than 24 levels of brightness (the flames and the flicker move; the room does
not). Writes <name>-diff.png next to a failing shot: the shot with its differing pixels painted red.

Usage: xrsim-compare.py BASELINE_DIR RUN_DIR
"""

import sys
from pathlib import Path

from PIL import Image, ImageChops

LEVELS = 24  # a channel's change that counts
SHARE = 0.02  # the share of changed pixels that fails a shot


def main(base: Path, run: Path) -> int:
    failed = 0
    for reference in sorted(base.glob("*.png")):
        if reference.stem.endswith("-diff"):
            continue
        shot = run / reference.name
        if not shot.exists():
            print(f"xrsim-compare: {reference.name}: missing")
            failed += 1
            continue
        old = Image.open(reference).convert("RGB")
        new = Image.open(shot).convert("RGB")
        if old.size != new.size:
            print(f"xrsim-compare: {reference.name}: size {new.size}, baseline {old.size}")
            failed += 1
            continue
        changed = ImageChops.difference(old, new).convert("L").point(lambda v: 255 if v > LEVELS else 0)
        share = changed.histogram()[255] / (old.width * old.height)
        print(f"xrsim-compare: {reference.name}: {share:.2%} changed")
        if share > SHARE:
            failed += 1
            red = Image.new("RGB", new.size, (255, 0, 0))
            Image.composite(red, new, changed).save(run / f"{shot.stem}-diff.png")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1]), Path(sys.argv[2])))
