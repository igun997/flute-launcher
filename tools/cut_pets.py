#!/usr/bin/env python3
"""Cuts the raw drawings in assets/_raw/pets/ into game-ready strips under assets/pets/<id>/ and
writes assets/pets/index.json. Needs numpy + pillow only.

  walk.png idle.png sleep.png happy.png   4 frames in a row, 160 px cells, transparent
  house.png                               256 px square, transparent
"""
import json, pathlib, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / "assets" / "_raw" / "pets"
OUT = ROOT / "assets" / "pets"
CELL = 160
HOUSE = 256

NAMES = {"pip": "Pip", "nori": "Nori", "sora": "Sora", "momo": "Momo", "kiri": "Kiri", "luma": "Luma"}
PHRASES = {
    "pip": ["Quack!", "Puddles are the best!", "Waddle waddle~", "Is it snack time?"],
    "nori": ["…nap time?", "So sleepy…", "Meow? I mean, hi.", "Five more minutes."],
    "sora": ["The sky looks nice!", "Float float~", "Hello hello!", "Cloud watching?"],
    "momo": ["Hop hop!", "Carrots? Carrots!", "Pet my ears~", "Boing!"],
    "kiri": ["Ribbit!", "Jump jump!", "I love rainy days!", "Croak~"],
    "luma": ["Make a wish!", "Sparkle sparkle~", "Stars are out soon!", "Abracadabra!"],
}


def sheet_alpha(rgb):
    """Transparent where the picture is near-white AND connected to the border (so white eyes,
    highlights and the like inside the outline stay)."""
    near = ((rgb[..., 0] > 236) & (rgb[..., 1] > 236) & (rgb[..., 2] > 236)).astype(np.uint8) * 255
    mask = Image.fromarray(near, "L")
    h, w = near.shape
    seeds = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] + [(x, 0) for x in range(0, w, 40)] + [(x, h - 1) for x in range(0, w, 40)] \
        + [(0, y) for y in range(0, h, 40)] + [(w - 1, y) for y in range(0, h, 40)]
    for sd in seeds:
        if mask.getpixel(sd) == 255:
            ImageDraw.floodfill(mask, sd, 128)
    bg = (np.asarray(mask) == 128)
    a = Image.fromarray(np.where(bg, 0, 255).astype(np.uint8), "L")
    a = a.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(0.8))
    return np.asarray(a)


def clean_cell(sub):
    """Removes slivers of the neighbouring figure that the equal-quarter crop cut through: small
    pieces that touch the crop's border. Pieces inside (a floating z, sparkles) stay."""
    from collections import deque
    a = np.asarray(sub.getchannel("A")) > 40
    h, w = a.shape
    lab = np.zeros((h, w), np.int32); n = 0; sizes = {}; touches = {}
    for y in range(h):
        for x in range(w):
            if a[y, x] and lab[y, x] == 0:
                n += 1; q = deque([(y, x)]); lab[y, x] = n; cnt = 0; edge = False
                while q:
                    cy, cx = q.popleft(); cnt += 1
                    if cy in (0, h - 1) or cx in (0, w - 1): edge = True
                    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)):
                        ny, nx = cy + dy, cx + dx
                        if 0 <= ny < h and 0 <= nx < w and a[ny, nx] and lab[ny, nx] == 0:
                            lab[ny, nx] = n; q.append((ny, nx))
                sizes[n] = cnt; touches[n] = edge
    if not sizes: return sub
    biggest = max(sizes.values())
    drop = [k for k, c in sizes.items() if touches[k] and c < 0.15 * biggest]
    if drop:
        arr = np.asarray(sub).copy()
        arr[np.isin(lab, drop)] = 0
        return Image.fromarray(arr, "RGBA")
    return sub


def cut_sheet(path, pid):
    raw = Image.open(path)
    if raw.mode == "RGBA" and np.asarray(raw.getchannel("A")).min() < 200:
        # The model already returned a transparent background: use it as is.
        rgb = np.asarray(raw.convert("RGB"))
        alpha = np.asarray(raw.getchannel("A").filter(ImageFilter.GaussianBlur(0.5)))
    else:
        rgb = np.asarray(raw.convert("RGB"))
        alpha = sheet_alpha(rgb)
    h, w = alpha.shape
    ch, cw = h // 4, w // 4
    frames = [[None] * 4 for _ in range(4)]
    boxes = [[None] * 4 for _ in range(4)]
    clipped = [[False] * 4 for _ in range(4)]
    for r in range(4):
        for c in range(4):
            sub = Image.fromarray(np.dstack([rgb[r*ch:(r+1)*ch, c*cw:(c+1)*cw], alpha[r*ch:(r+1)*ch, c*cw:(c+1)*cw]]), "RGBA")
            sub = clean_cell(sub)
            _al = np.asarray(sub.getchannel('A')) > 40
            _c = int(_al[0].sum() + _al[-1].sum() + _al[:, 0].sum() + _al[:, -1].sum())
            clipped[r][c] = _c > 5
            if _c > 5: print('CLIPPED', pid, 'row', r, 'col', c, 'contact px', _c)
            bb = sub.getchannel("A").point(lambda v: 255 if v > 40 else 0).getbbox()
            if bb is None:
                raise SystemExit(f"{pid}: empty cell r{r} c{c}")
            frames[r][c] = sub.crop(bb)
            boxes[r][c] = bb
    # A figure the model drew across a cell boundary comes out with a hard vertical edge. Idle
    # frames like that are rebuilt from the clean standing frame, breathing by a pixel or two.
    for c in range(4):
        if clipped[1][c]:
            base = frames[0][0]; squash = 1.0 if c % 2 == 0 else 0.982
            f = base.resize((base.width, max(1, round(base.height * squash))), Image.LANCZOS)
            frames[1][c] = f
            x0, y0, x1, y1 = boxes[0][0]
            boxes[1][c] = (x0, y1 - f.height, x1, y1)
    # Common scale: standing rows (walk, idle, happy) share one factor, sleeping has its own.
    def fit(rows):
        mw = max(f.width for r in rows for f in frames[r]); mh = max(f.height for r in rows for f in frames[r])
        return min((CELL - 14) / mw, (CELL - 14) / mh)
    s_stand = fit([0, 1, 3]); s_sleep = fit([2])
    strips = {}
    for r, name in enumerate(["walk", "idle", "sleep", "happy"]):
        s = s_sleep if r == 2 else s_stand
        scaled = [f.resize((max(1, round(f.width * s)), max(1, round(f.height * s))), Image.LANCZOS) for f in frames[r]]
        # keep each frame's height relative to the row's lowest foot so jumps stay jumps
        bottoms = [boxes[r][c][3] * s for c in range(4)]
        base = max(bottoms)
        strip = Image.new("RGBA", (CELL * 4, CELL), (0, 0, 0, 0))
        for c, f in enumerate(scaled):
            lift = base - bottoms[c]
            x = c * CELL + (CELL - f.width) // 2
            y = int(CELL - 6 - f.height - lift)
            strip.alpha_composite(f, (x, max(0, y)))
        strips[name] = strip
    d = OUT / pid; d.mkdir(parents=True, exist_ok=True)
    for name, strip in strips.items():
        strip.save(d / f"{name}.png", optimize=True)


def cut_house(path, pid):
    im = Image.open(path).convert("RGB"); a = np.asarray(im).astype(int)
    dist = np.sqrt((a[..., 0] - 255) ** 2 + a[..., 1] ** 2 + (a[..., 2] - 255) ** 2)
    alpha = np.clip((dist - 40) * 4, 0, 255).astype(np.uint8)
    rgba = Image.fromarray(np.dstack([a.astype(np.uint8), alpha]), "RGBA")
    bb = rgba.getchannel("A").point(lambda v: 255 if v > 40 else 0).getbbox()
    rgba = rgba.crop(bb)
    s = (HOUSE - 8) / max(rgba.width, rgba.height)
    rgba = rgba.resize((round(rgba.width * s), round(rgba.height * s)), Image.LANCZOS)
    out = Image.new("RGBA", (HOUSE, HOUSE), (0, 0, 0, 0))
    out.alpha_composite(rgba, ((HOUSE - rgba.width) // 2, HOUSE - 4 - rgba.height))
    # magenta fringe: pull colour toward neighbours by removing pink tint on semi-transparent pixels
    arr = np.asarray(out).astype(int)
    semi = (arr[..., 3] > 0) & (arr[..., 3] < 255)
    arr[semi, 0] = np.minimum(arr[semi, 0], arr[semi, 1] + 60)
    arr[semi, 2] = np.minimum(arr[semi, 2], arr[semi, 1] + 60)
    Image.fromarray(arr.astype(np.uint8), "RGBA").save(OUT / pid / "house.png", optimize=True)


if __name__ == "__main__":
    ids = [p.stem[:-6] for p in sorted(RAW.glob("*_sheet.png")) if (RAW / f"{p.stem[:-6]}_house.png").exists()]
    only = set(sys.argv[1:])
    done = []
    for pid in ids:
        if only and pid not in only: continue
        cut_sheet(RAW / f"{pid}_sheet.png", pid); cut_house(RAW / f"{pid}_house.png", pid); done.append(pid)
        print("cut", pid)
    allp = sorted(p.name for p in OUT.iterdir() if p.is_dir())
    (OUT / "index.json").write_text(json.dumps({"cell": CELL, "houseCell": HOUSE, "pets": [
        {"id": i, "name": NAMES.get(i, i.title()), "phrases": PHRASES.get(i, ["Hi!"])} for i in allp]}, indent=1))
    print("index", allp)
