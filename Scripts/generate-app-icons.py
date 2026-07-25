#!/usr/bin/env python3
"""Generate the iOS AppIcon appearance variants (light, dark, tinted) from the master art.

The master foreground carries a dark glow baked into its alpha (roughly a quarter of its
pixels are semi-transparent dark navy). That glow is authored for a black background, so
compositing it onto a light one leaves a dirty smudge. The motif separates cleanly on
brightness though: it sits at maxRGB >= 160, the glow stays at 32-63, and almost nothing
falls in between. `_strip_glow` ramps the alpha across that gap.

Usage: Scripts/generate-app-icons.py
"""

from pathlib import Path

from PIL import Image, ImageFilter

REPO = Path(__file__).resolve().parent.parent
MASTER = REPO / "Marketing/Icons/IconComposer_Source/foreground_transparent_1024.png"
DARK = REPO / "Marketing/Icons/AppStore/icon_1024x1024.png"
OUT = REPO / "Sodalite/Assets.xcassets/AppIcon.appiconset"
SIZE = 1024

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


def _light_background() -> Image.Image:
    bg = Image.new("RGBA", (SIZE, SIZE))
    px = bg.load()
    for y in range(SIZE):
        t = y / (SIZE - 1)
        row = (int(247 - 10 * t), int(249 - 8 * t), int(255 - 6 * t), 255)
        for x in range(SIZE):
            px[x, y] = row
    return bg


def _drop_shadow(motif: Image.Image) -> Image.Image:
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow.paste((40, 70, 180, 90), (0, 0), motif.getchannel("A"))
    return shadow.filter(ImageFilter.GaussianBlur(28))


def main() -> None:
    motif = _strip_glow(Image.open(MASTER).convert("RGBA"))

    light = Image.alpha_composite(_light_background(), _drop_shadow(motif))
    light = Image.alpha_composite(light, motif).convert("RGB")
    light.save(OUT / "icon_light_1024.png")

    # Tinted: grayscale on black, the system maps luminance onto the user's tint.
    tinted = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 255))
    tinted = Image.alpha_composite(tinted, motif).convert("L").convert("RGB")
    tinted.save(OUT / "icon_tinted_1024.png")

    # Dark stays the shipped artwork, glow and all; it is what that glow was drawn for.
    Image.open(DARK).convert("RGB").save(OUT / "icon_dark_1024.png")

    for name in ("icon_light_1024.png", "icon_dark_1024.png", "icon_tinted_1024.png"):
        print(f"  wrote {name}")


if __name__ == "__main__":
    main()
