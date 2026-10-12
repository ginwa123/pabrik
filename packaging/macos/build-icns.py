#!/usr/bin/env python3
"""Repack packaging/icons/pabrik-*.png into packaging/macos/Pabrik.icns.

The .icns format is a plain container: magic `icns`, a be32 total length,
then `OSType (4 ascii) + be32 element length + payload` elements. macOS
10.5+ accepts PNG payloads for the ic07-family elements, so no iconutil
or macOS host is needed — this runs anywhere Python 3 does.

Element set mirrors what iconutil emits for a full iconset (ic11/ic12
small sizes plus the ic07..ic10 retina ladder, with the ic13/ic14
duplicates iconutil also writes).

Usage:  python3 packaging/macos/build-icns.py   (from the repo root)
"""

import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "icons"

# (png size, icns OSType)
ELEMENTS = [
    (32, "ic11"),
    (64, "ic12"),
    (128, "ic07"),
    (128, "ic14"),
    (256, "ic08"),
    (256, "ic13"),
    (512, "ic09"),
    (1024, "ic10"),
]


def main() -> None:
    body = bytearray()
    for px, tag in ELEMENTS:
        png = (ICONS / f"pabrik-{px}.png").read_bytes()
        body += tag.encode("ascii") + struct.pack(">I", 8 + len(png)) + png
    out = ROOT / "macos" / "Pabrik.icns"
    out.write_bytes(b"icns" + struct.pack(">I", 8 + len(body)) + bytes(body))
    print(f"wrote {out} ({out.stat().st_size} bytes, {len(ELEMENTS)} elements)")


if __name__ == "__main__":
    sys.exit(main())
