#!/usr/bin/env python3
"""Makes Resources/IntelligenceLoops.png from Resources/IntelligenceMark.png, the supplied artwork.

The app draws the Apple Intelligence mark in the skin's colours: its own tile, and the seven loops
filled with a gradient of the skin's accent. This keeps only the loops' shape, as white with
transparency. Pixels count as loop by how far their colour is from the light tile behind them.
Run by hand (Pillow and numpy); not run in CI.
"""
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Resources" / "IntelligenceMark.png"
OUTPUT = ROOT / "Resources" / "IntelligenceLoops.png"
TILE = np.array([241.0, 242.0, 244.0])  # the tile's own colour
EDGE = 35.0    # differences below this are the tile's shading and rim
FULL = 95.0    # from here on a pixel is fully loop


def main() -> None:
    image = np.asarray(Image.open(SOURCE).convert("RGBA")).astype(float)
    rgb, alpha = image[..., :3], image[..., 3] / 255.0
    distance = np.sqrt(((rgb - TILE) ** 2).sum(axis=-1))
    loops = np.clip((distance - EDGE) / (FULL - EDGE), 0, 1)
    # Only inside the tile: the transparent margin and its drop shadow are never loop.
    loops *= np.clip((alpha - 0.9) / 0.1, 0, 1)
    # The loops sit in a circle in the middle; the tile's rim and corners lie outside it.
    height, width = loops.shape
    ys, xs = np.mgrid[0:height, 0:width]
    radius = np.hypot(xs - (width - 1) / 2, ys - (height - 1) / 2)
    loops *= radius <= width * 0.37
    out = np.zeros((height, width, 4), dtype=np.uint8)
    out[..., :3] = 255
    out[..., 3] = (loops * 255).round().astype(np.uint8)
    Image.fromarray(out, "RGBA").save(OUTPUT)
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({width}x{height})")


if __name__ == "__main__":
    main()
