#!/usr/bin/env python3
"""Draws the original pet characters (sprite sheet + house each) with the image model.
Raw pictures go to assets/_raw/pets/ (not shipped); tools/cut_pets.py turns them into assets/pets/."""
import subprocess, sys, concurrent.futures as cf, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / "assets" / "_raw" / "pets"

CHARS = {
 "pip":  ("a chibi girl with short cream-yellow hair, a yellow raincoat with a duck-bill hood, small orange boots",
          "a cosy yellow cottage shaped like a round duck, orange beak-shaped porch roof, round door, tiny window"),
 "nori": ("a chibi girl with messy black hair and black cat ears, an oversized teal hoodie, sleepy half-closed eyes",
          "a snug teal hut with two pointed cat-ear shaped roof tips, round window, wooden door"),
 "sora": ("a chibi girl with long light-blue twin tails, a white sailor dress, a small cloud-shaped hair clip",
          "a fluffy white cloud-shaped cottage with a pale blue roof, round door, tiny window"),
 "momo": ("a chibi girl with peach-pink hair and long floppy bunny ears, a pastel pink sweater and skirt",
          "a pink cottage with a big orange carrot-shaped chimney, round door, tiny window"),
 "kiri": ("a chibi girl with short mint-green hair wearing a green frog hood with two round eyes on top, olive overalls",
          "a green mushroom-cap house with white spots, round door, tiny window"),
 "luma": ("a chibi girl with lavender hair and a star hair clip, a dark purple cape, holding a tiny star wand",
          "a small purple tower house with a crescent moon on top, star-shaped window, arched door"),
}

SHEET = ("Game sprite sheet of ONE original cute chibi character: {d}. Flat pure magenta (#FF00FF) background everywhere, "
         "no ground, no shadows, no text, no labels. Exactly a 4-column by 4-row grid of equal square cells with generous empty space "
         "between figures; every figure fully inside its own cell and never touching a neighbour. Same character, same proportions, "
         "same colours in every cell. Thick dark outline, flat cel shading, kawaii, big head. "
         "Row 1: side view facing right, 4-frame walk cycle. "
         "Row 2: standing idle facing right, 4 frames: breathing, blinking, tiny head tilt, breathing. "
         "Row 3: sleeping curled up on her side with closed eyes, 4 frames: slow breathing, a small z floating above in the last two frames. "
         "Row 4: happy reaction facing the viewer, 4 frames: wave, jump up, land, sparkle eyes. No real-world brands or existing characters.")
HOUSE = ("One cute tiny game-asset house, front view, flat pure magenta (#FF00FF) background, no ground, no shadow, no text. "
         "Pastel cel-shaded kawaii style with a thick dark outline. {d}. The door is clearly visible and the window is a plain light glass pane.")

def run(job):
    key, kind, prompt = job
    out = RAW / f"{key}_{kind}.png"
    r = subprocess.run(["python3", str(ROOT / "tools" / "gen.py"), "image", str(out), prompt, "--model", "cx/gpt-6.1-sol", "--size", "1024x1024"],
                       capture_output=True, text=True, cwd=ROOT)
    return key, kind, r.returncode, (r.stdout + r.stderr).strip()[-100:]

if __name__ == "__main__":
    only = set(sys.argv[1:])
    jobs = []
    for k, (d, h) in CHARS.items():
        if only and k not in only: continue
        jobs.append((k, "sheet", SHEET.format(d=d)))
        jobs.append((k, "house", HOUSE.format(d=h)))
    RAW.mkdir(parents=True, exist_ok=True)
    with cf.ThreadPoolExecutor(4) as ex:
        for k, kind, rc, msg in ex.map(run, jobs):
            print(k, kind, rc, msg)
