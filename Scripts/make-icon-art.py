#!/usr/bin/env python3
"""Draws EchoNyla's icon: a silver page with a chevron dropping into a silver tray, on Verbyn's black tile.

The skins and their colours are Verbyn's (Scripts/make-skin-icons.py there): Signature is the app's
built-in icon (black tile, silver glyph, near-black chevron); the other five recolour the same drawing
(the skin's dark tile, the glyph in the skin's bright gradient, a white chevron).

Writes, from the repository root:
    Resources/AppIcon.icon/Assets/glyph.png   the page and tray alone, for Icon Composer (macOS draws the tile)
    Resources/AppIcon-1024.png                Signature edge to edge with no shadow (the .icns fallback)
    docs/images/echonyla-icon.png             the same, for the README
    Resources/SkinIcons/icon-<skin>.png       the Dock and Finder icon of every other skin (824 tile, soft shadow)

Run by hand after changing the art (needs Pillow and numpy); not run in CI:
    python3 Scripts/make-icon-art.py
"""
import pathlib

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 4  # drawn at 4096 and scaled down, for smooth edges


def hex_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


# tile: bottom, middle, top. glyph: lower right (deep), middle, upper left (light).
# edge: the glyph's thin outline. chevron: bottom and top of the chevron. rim: the tile's fine edge.
SKINS = {
    "signature": dict(tile=("#050607", "#0B0C0D", "#1A1B1E"), glyph=("#3A3B3F", "#8D8F93", "#F4F4F5"), edge="#FFFFFF",
                      rim="#D9DADC", chevron=("#0B0C0D", "#2A2B2E")),
    "sky": dict(tile=("#060B1B", "#0B1733", "#14335F"), glyph=("#053AFF", "#00A1FF", "#0DF0F2"), edge="#80F5FF", rim="#408CF2"),
    "green": dict(tile=("#04110B", "#0A2218", "#0F3D2A"), glyph=("#0B7A44", "#24B86C", "#86F2B4"), edge="#B5FFD2", rim="#7CE2A3"),
    "turquoise": dict(tile=("#041213", "#082426", "#0C3B3D"), glyph=("#0E7A75", "#2EC2B8", "#93F5EC"), edge="#C2FFF9", rim="#5FD0C8"),
    "bordeaux": dict(tile=("#130609", "#2A0D15", "#4A1624"), glyph=("#A1263F", "#E06A81", "#FFC4CE"), edge="#FFD9DF", rim="#E8909F"),
    "wisteria": dict(tile=("#0B0917", "#1A1533", "#2E2558"), glyph=("#5A44C0", "#957EEE", "#E0D6FF"), edge="#EDE6FF", rim="#B9A6F2"),
}
# Every skin in Sources/EchoNylaCore/Skins.swift except Signature, whose icon is the app's own.
SKIN_ICONS = ["sky", "green", "turquoise", "bordeaux", "wisteria"]

# The drawing, in a y-down 1024 grid (the mock-up's icon A, scaled from its 100-unit box).
PAGE = [(348, 184), (573, 184), (686, 297), (686, 614), (348, 614)]
FOLD = [(573, 184), (573, 297), (686, 297)]
CHEVRON = [(440, 369), (512, 441), (584, 369)]
TRAY_TOP, TRAY_BOTTOM, TRAY_LEFT, TRAY_RIGHT, TRAY_RADIUS = 563, 829, 195, 829, 102
NOTCH = [(348, 563), (389, 645), (635, 645), (676, 563)]  # where the page goes in


def scaled(points):
    return [(x * SCALE, y * SCALE) for x, y in points]


def tray_points():
    """The tray's outline: flat top with a notch, rounded bottom corners."""
    points = [(TRAY_LEFT, TRAY_TOP)] + NOTCH + [(TRAY_RIGHT, TRAY_TOP), (TRAY_RIGHT, TRAY_BOTTOM - TRAY_RADIUS)]
    for i in range(1, 33):  # bottom right corner
        a = np.radians(90 * i / 32)
        points.append((TRAY_RIGHT - TRAY_RADIUS + TRAY_RADIUS * np.cos(a), TRAY_BOTTOM - TRAY_RADIUS + TRAY_RADIUS * np.sin(a)))
    points.append((TRAY_LEFT + TRAY_RADIUS, TRAY_BOTTOM))
    for i in range(1, 33):  # bottom left corner
        a = np.radians(90 + 90 * i / 32)
        points.append((TRAY_LEFT + TRAY_RADIUS + TRAY_RADIUS * np.cos(a), TRAY_BOTTOM - TRAY_RADIUS + TRAY_RADIUS * np.sin(a)))
    return points


def gradient(stops, angle_degrees, bounds):
    """A linear gradient across bounds (x0, y0, x1, y1, y-down); 90 degrees runs bottom to top."""
    n = SIZE * SCALE
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float32)
    gx = xs / SCALE
    gy = SIZE - ys / SCALE
    angle = np.radians(angle_degrees)
    dx, dy = np.cos(angle), np.sin(angle)
    x0, y0, x1, y1 = bounds
    corners = [x * dx + (SIZE - y) * dy for x in (x0, x1) for y in (y0, y1)]
    low, high = min(corners), max(corners)
    t = np.clip((gx * dx + gy * dy - low) / (high - low), 0, 1)
    colours = [np.array(hex_rgb(s), dtype=np.float32) for s in stops]
    positions = np.linspace(0, 1, len(colours))
    out = np.zeros((n, n, 3), dtype=np.float32)
    for channel in range(3):
        out[..., channel] = np.interp(t, positions, [c[channel] for c in colours])
    return Image.fromarray(out.astype(np.uint8), "RGB")


def mask(draw_shape):
    image = Image.new("L", (SIZE * SCALE, SIZE * SCALE), 0)
    draw_shape(ImageDraw.Draw(image))
    return image


def icon(skin, with_tile=True, with_shadow=True):
    colours = SKINS[skin]
    n = SIZE * SCALE
    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    separator = hex_rgb(colours["tile"][1])

    if with_tile:
        tile_box = [100 * SCALE, 100 * SCALE, 924 * SCALE, 924 * SCALE]
        tile = mask(lambda d: d.rounded_rectangle(tile_box, radius=185 * SCALE, fill=255))
        canvas.paste(gradient(colours["tile"], 90, (100, 100, 924, 924)), (0, 0), tile)
        rim = mask(lambda d: d.rounded_rectangle(tile_box, radius=185 * SCALE, outline=255, width=2 * SCALE))
        canvas.paste(Image.new("RGB", (n, n), hex_rgb(colours["rim"])), (0, 0), rim.point(lambda v: int(v * 0.28)))

    glyph_fill = gradient(colours["glyph"], 125, (195, 184, 829, 829))
    edge_colour = Image.new("RGB", (n, n), hex_rgb(colours["edge"]))

    # The page, behind the tray.
    page = mask(lambda d: d.polygon(scaled(PAGE), fill=255))
    canvas.paste(glyph_fill, (0, 0), page)
    page_edge = mask(lambda d: d.line(scaled(PAGE + PAGE[:1]), fill=255, width=int(1.5 * SCALE)))
    canvas.paste(edge_colour, (0, 0), page_edge.point(lambda v: int(v * 0.38)))
    fold = mask(lambda d: d.polygon(scaled(FOLD), fill=255))
    canvas.paste(Image.new("RGB", (n, n), separator), (0, 0), fold.point(lambda v: int(v * 0.35)))
    fold_line = mask(lambda d: d.line(scaled(FOLD), fill=255, width=6 * SCALE, joint="curve"))
    canvas.paste(Image.new("RGB", (n, n), separator), (0, 0), fold_line)

    chevron = mask(lambda d: (d.line(scaled(CHEVRON), fill=255, width=37 * SCALE, joint="curve"),
                              [d.ellipse([(x - 18.5) * SCALE, (y - 18.5) * SCALE, (x + 18.5) * SCALE, (y + 18.5) * SCALE], fill=255)
                               for x, y in CHEVRON]))
    canvas.paste(gradient(colours.get("chevron", ("#E3F2FF", "#FFFFFF")), 90, (440, 369, 584, 441)), (0, 0), chevron)

    # The tray in front, with a dark outline so it stands apart from the page.
    tray = tray_points()
    outline = mask(lambda d: d.line(scaled(tray + tray[:1]), fill=255, width=22 * SCALE, joint="curve"))
    canvas.paste(Image.new("RGB", (n, n), separator), (0, 0), outline)
    body = mask(lambda d: d.polygon(scaled(tray), fill=255))
    canvas.paste(glyph_fill, (0, 0), body)
    tray_edge = mask(lambda d: d.line(scaled(tray + tray[:1]), fill=255, width=int(1.5 * SCALE)))
    canvas.paste(edge_colour, (0, 0), tray_edge.point(lambda v: int(v * 0.38)))

    canvas = canvas.resize((SIZE, SIZE), Image.LANCZOS)
    if not with_shadow:
        return canvas

    # A soft shadow under the tile, as macOS draws under app icons.
    shadow_mask = Image.new("L", (SIZE, SIZE), 0)
    shadow_mask.paste(canvas.getchannel("A").point(lambda v: int(v * 0.45)), (0, 12))
    shadow = Image.new("RGBA", (SIZE, SIZE), hex_rgb(colours["tile"][0]) + (0,))
    shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(14)))
    return Image.alpha_composite(shadow, canvas)


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    outputs = {
        root / "Resources" / "AppIcon.icon" / "Assets" / "glyph.png": icon("signature", with_tile=False, with_shadow=False),
        root / "Resources" / "AppIcon-1024.png": icon("signature", with_shadow=False),
        root / "docs" / "images" / "echonyla-icon.png": icon("signature", with_shadow=False),
    }
    for skin in SKIN_ICONS:
        outputs[root / "Resources" / "SkinIcons" / f"icon-{skin}.png"] = icon(skin)
    for path, image in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        image.save(path, optimize=True)
        print(f"wrote {path.relative_to(root)}")


if __name__ == "__main__":
    main()
