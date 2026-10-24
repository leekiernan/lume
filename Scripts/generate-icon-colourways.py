#!/usr/bin/env python3
"""Generate lume's app icon in each colour theme (`LumeColorTheme`).

The Afterglow mark from the logo design board (240-unit artboard, centroid at
110,120): a solid play triangle, an inner ring at 60% and an outer ring at
30%, drawn in the theme's bright shade on Ink.

- iPhone, iPad, Mac: `Lume/<Name>.icon`, a copy of `Lume/Lume.icon` with the
  layers' fill set to the theme's colour. The layer SVGs are white; Icon
  Composer tints them.
- Apple TV: `Lume/Assets.xcassets/<Name>TV.imagestack`, the parallax icon's
  three layers rendered as PNGs as the shipped `Lume.brandassets` has them:
  the triangle in front, the rings in the middle, and the brand ground behind (`LumeAmbientBackground`'s `.brand`
  style: Ink, the theme's glow from the centre and its bright shade faintly
  from the bottom-leading corner).

    Scripts/generate-icon-colourways.py           # write the alternates
    Scripts/generate-icon-colourways.py --check   # re-render pink and compare
                                                  # it with the shipped icon

Needs `rsvg-convert` and ImageMagick (`brew install librsvg imagemagick`).
Keep THEMES in step with `LumeColorTheme.hex`.
"""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Lume"
CATALOG = APP / "Assets.xcassets"

INK = "#14101F"
# name: (bright, glow) — the theme's bright shade and its ambient glow hue.
THEMES = {
    "Lume": ("#FF88D7", "#7000B4"),
    "LumeIce": ("#62DEFF", "#0B3FA8"),
    "LumeCoral": ("#FF6247", "#8A1240"),
    "LumeGreen": ("#CCFF4D", "#0A6B4F"),
}

TRIANGLE = "M-12 -48.5L48 -13.86A16 16 0 0 1 48 13.86L-12 48.5A16 16 0 0 1 -36 34.64L-36 -34.64A16 16 0 0 1 -12 -48.5Z"
INNER = "M-2 -65.82L58 -31.18A36 36 0 0 1 58 31.18L-2 65.82A36 36 0 0 1 -56 34.64L-56 -34.64A36 36 0 0 1 -2 -65.82Z"
OUTER = "M11 -88.33L71 -53.69A62 62 0 0 1 71 53.69L11 88.33A62 62 0 0 1 -82 34.64L-82 -34.64A62 62 0 0 1 11 -88.33Z"

# Each stack's sizes, as the shipped `Lume.brandassets` has them.
STACKS = {
    "App Icon": [(400, 240, "1x"), (800, 480, "2x")],
    "App Icon - App Store": [(1280, 768, "1x")],
}


def mark_transform(width, height):
    """The mark in a 300-point box at 800 wide, centred, its centroid 10 units
    left of centre as on the artboard."""
    scale = width / 640
    return f"translate({width / 2 - 10 * scale} {height / 2}) scale({scale})"


def front_svg(width, height, bright):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">'
            f'<g transform="{mark_transform(width, height)}"><path d="{TRIANGLE}" fill="{bright}"/></g></svg>')


def middle_svg(width, height, bright):
    ring = 'fill="none" stroke="{}" stroke-width="12" opacity="{}"'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">'
            f'<g transform="{mark_transform(width, height)}">'
            f'<path d="{INNER}" {ring.format(bright, 0.6)}/><path d="{OUTER}" {ring.format(bright, 0.3)}/>'
            f'</g></svg>')


def back_svg(width, height, bright, glow):
    """`LumeAmbientBackground(.brand)`: ellipses sized for a 1920-wide board,
    each fading from its colour to clear at 70% of its radii."""
    unit = width / 1920

    def ellipse(ident, colour, opacity, board_w, board_h, cx, cy):
        return (f'<radialGradient id="{ident}"><stop offset="0" stop-color="{colour}" stop-opacity="{opacity}"/>'
                f'<stop offset="1" stop-color="{colour}" stop-opacity="0"/></radialGradient>',
                f'<ellipse cx="{cx}" cy="{cy}" rx="{board_w * unit * 0.7}" ry="{board_h * unit * 0.7}" fill="url(#{ident})"/>')

    violet = ellipse("g", glow, 0.5, 760, 540, width * 0.5, height * 0.44)
    accent = ellipse("a", bright, 0.12, 900, 600, width * 0.12, height)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">'
            f'<defs>{violet[0]}{accent[0]}</defs><rect width="{width}" height="{height}" fill="{INK}"/>'
            f'{violet[1]}{accent[1]}</svg>')


def render(svg, out):
    subprocess.run(["rsvg-convert", "-o", str(out)], input=svg.encode(), check=True)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def write_stack(stack_dir, sizes, bright, glow):
    """One parallax image stack: Front, Middle and Back layers."""
    stack_dir.mkdir(parents=True)
    layers = ["Front", "Middle", "Back"]
    write_json(stack_dir / "Contents.json", {"info": {"author": "xcode", "version": 1},
                                             "layers": [{"filename": f"{layer}.imagestacklayer"} for layer in layers]})
    for layer in layers:
        layer_dir = stack_dir / f"{layer}.imagestacklayer"
        content = layer_dir / "Content.imageset"
        content.mkdir(parents=True)
        write_json(layer_dir / "Contents.json", {"info": {"author": "xcode", "version": 1}})
        images = []
        for width, height, scale in sizes:
            filename = f"{layer.lower()}_{width}.png"
            svg = {"Front": front_svg(width, height, bright), "Middle": middle_svg(width, height, bright),
                   "Back": back_svg(width, height, bright, glow)}[layer]
            render(svg, content / filename)
            images.append({"filename": filename, "idiom": "tv", "scale": scale})
        write_json(content / "Contents.json", {"images": images, "info": {"author": "xcode", "version": 1}})


def write_tv_alternate(name, bright, glow):
    """tvOS takes an alternate icon as a top-level image stack, not brand
    assets, and only the home-screen sizes: the App Store icon is the
    primary's. Suffixed `TV`, as actool would otherwise take the same-named
    `.icon` for it."""
    stack = CATALOG / f"{name}TV.imagestack"
    shutil.rmtree(stack, ignore_errors=True)
    write_stack(stack, STACKS["App Icon"], bright, glow)


def extended_srgb(hex_colour):
    channels = [int(hex_colour[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    return "extended-srgb:" + ",".join(f"{value:.5f}" for value in channels) + ",1.00000"


def write_icon(name, bright):
    source = APP / "Lume.icon"
    target = APP / f"{name}.icon"
    shutil.rmtree(target, ignore_errors=True)
    shutil.copytree(source, target)
    icon = json.loads((source / "icon.json").read_text())
    for group in icon["groups"]:
        for layer in group["layers"]:
            layer["fill"] = {"solid": extended_srgb(bright)}
    (target / "icon.json").write_text(json.dumps(icon, indent=2, sort_keys=True).replace('": ', '" : ') + "\n")


def check():
    """Re-render pink and measure it against the shipped `Lume.brandassets`."""
    bright, glow = THEMES["Lume"]
    shipped_assets = CATALOG / "Lume.brandassets"
    with tempfile.TemporaryDirectory() as scratch:
        for stack, sizes in STACKS.items():
            write_stack(Path(scratch) / f"{stack}.imagestack", sizes, bright, glow)
        worst = 0.0
        for png in sorted(Path(scratch).rglob("*.png")):
            shipped = shipped_assets / png.relative_to(scratch)
            result = subprocess.run(["magick", "compare", "-metric", "RMSE", str(shipped), str(png), "null:"],
                                    capture_output=True, text=True)
            score = float(result.stderr.split("(")[1].split(")")[0])
            worst = max(worst, score)
            print(f"{score:.4f}  {png.relative_to(scratch)}")
        print(f"worst RMSE {worst:.4f}")
        return worst


def main():
    if "--check" in sys.argv:
        # Antialiasing alone differs by under 3%; a misplaced or recoloured
        # layer by far more.
        sys.exit(0 if check() < 0.03 else 1)
    for name, (bright, glow) in THEMES.items():
        if name == "Lume":
            continue
        write_tv_alternate(name, bright, glow)
        write_icon(name, bright)
        print(f"wrote {name}.icon and {name}TV.imagestack")


if __name__ == "__main__":
    main()
