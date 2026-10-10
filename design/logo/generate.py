"""Renders Sidelight's icon: a soft band of light along the left edge, where the panel lives, on deep navy.

Outputs:
- design/logo/sidelight-icon.png: the 1024 px master on Apple's icon grid (rounded tile, transparent margin),
  for the README, the website and anything else outside the app.
- Resources/AppIcon.icon/Assets/light.png: the same artwork full-bleed, the layer Icon Composer and actool
  turn into the app icon. macOS applies the rounded shape itself.

Run with a Python that has numpy and Pillow:  python3 design/logo/generate.py
"""

from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SIZE = 1024
NAVY = "#0E0F1A"
# Three soft lights stacked along the left edge, warm at the top and cool at the bottom: (x, y, spread x, y).
LIGHTS = [((60, 300, 170, 260), "#FFB38A"), ((60, 560, 170, 240), "#FF8FB8"), ((60, 820, 170, 260), "#B7A1FF")]
STRENGTH = 0.8
GRAIN = 0.045
# Apple's icon grid: an 824 px tile with 185 px corners, centered on the 1024 px canvas.
TILE_ORIGIN, TILE_SIZE, TILE_RADIUS = 100, 824, 185


def rgb(hex_color):
    return np.array([int(hex_color[i : i + 2], 16) for i in (1, 3, 5)], float)


def artwork(x, y):
    """The icon at tile coordinates `x`, `y` (the master's own pixel grid), as unclipped RGB."""
    light = sum(
        np.exp(-((x - cx) ** 2 / (2 * sx * sx) + (y - cy) ** 2 / (2 * sy * sy)))[..., None] * rgb(color)
        for (cx, cy, sx, sy), color in LIGHTS
    )
    grain = np.random.default_rng(7).normal(0, GRAIN, (SIZE // 2, SIZE // 2))
    grain = np.kron(grain, np.ones((2, 2)))  # 2 px grain
    return rgb(NAVY) + light * STRENGTH + (grain * 255)[..., None]


def tile_alpha(supersampling=2):
    """The rounded tile's coverage per pixel, antialiased by supersampling."""
    n = SIZE * supersampling
    ys, xs = np.mgrid[0:n, 0:n].astype(float)
    x, y = (xs + 0.5) / supersampling, (ys + 0.5) / supersampling
    half, center = TILE_SIZE / 2, TILE_ORIGIN + TILE_SIZE / 2
    dx = np.maximum(np.abs(x - center) - (half - TILE_RADIUS), 0)
    dy = np.maximum(np.abs(y - center) - (half - TILE_RADIUS), 0)
    inside = (np.abs(x - center) <= half) & (np.abs(y - center) <= half) & (dx * dx + dy * dy <= TILE_RADIUS**2 + 1e-9)
    return inside.reshape(SIZE, supersampling, SIZE, supersampling).mean(axis=(1, 3))


def main():
    centers = np.arange(SIZE) + 0.5
    x, y = np.meshgrid(centers, centers)

    master = np.dstack([np.clip(artwork(x, y), 0, 255), tile_alpha() * 255]).astype(np.uint8)
    Image.fromarray(master, "RGBA").save(Path(__file__).with_name("sidelight-icon.png"))

    # Full bleed: the tile's 824 px stretched over the whole canvas, for the system to mask.
    scale = TILE_SIZE / SIZE
    layer = np.clip(artwork(TILE_ORIGIN + x * scale, TILE_ORIGIN + y * scale), 0, 255).astype(np.uint8)
    out = ROOT / "Resources" / "AppIcon.icon" / "Assets" / "light.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(layer, "RGB").save(out)


if __name__ == "__main__":
    main()
