#!/usr/bin/env python3
"""Refresh the transparent motif inside the iOS AppIcon.icon package.

The icon itself is an Icon Composer package: Sodalite/Platforms/iOS/AppIcon.icon holds
icon.json (background fill plus one layer) and Assets/motif.png. actool compiles it and
renders the light, dark and tinted appearances from that single motif, so there is nothing
to composite here beyond producing a clean cutout.

The master foreground carries a dark glow baked into its alpha, authored for a black
background, which would show up as grime once the system puts the motif on a light one.
The motif separates cleanly on brightness: it sits at maxRGB >= 160, the glow stays at
32-63, and almost nothing falls in between, so an alpha ramp across that gap removes it.

Usage: Scripts/generate-app-icons.py
"""

from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
MASTER = REPO / "Marketing/Icons/IconComposer_Source/foreground_transparent_1024.png"
MOTIF = REPO / "Marketing/Icons/IconComposer_Source/motif_transparent_1024.png"
ICON_ASSET = REPO / "Sodalite/Platforms/iOS/AppIcon.icon/Assets/motif.png"

# Alpha ramp bounds on max(R,G,B); below GLOW_LO is glow, above GLOW_HI is motif.
GLOW_LO, GLOW_HI = 64, 128


def _smoothstep(edge0: int, edge1: int, x: int) -> float:
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def _strip_glow(src: Image.Image) -> Image.Image:
    out = src.copy()
    px = out.load()
    for x in range(out.width):
        for y in range(out.height):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            px[x, y] = (r, g, b, int(a * _smoothstep(GLOW_LO, GLOW_HI, max(r, g, b))))
    return out


def main() -> None:
    motif = _strip_glow(Image.open(MASTER).convert("RGBA"))
    for path in (MOTIF, ICON_ASSET):
        motif.save(path)
        print(f"  wrote {path.relative_to(REPO)}")


if __name__ == "__main__":
    main()
