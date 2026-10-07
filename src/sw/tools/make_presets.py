"""Preset still images of the TX (GUI button "预设", src preset:<name>): DIV2K validation images 0801 / 0802 / 0803 /
0830 / 0843 (the images of Fig. 4 of the GLOBECOM 2025 FPGA DeepJSCC paper), centre square crop of the full height,
area (box) resize to 256 x 256 RGB. The DIV2K images are not redistributed here: download DIV2K_valid_HR from
https://data.vision.ee.ethz.ch/cvl/DIV2K/ and run

    python make_presets.py <DIV2K_valid_HR dir> <out dir>      (then copy <out dir> to the TX board: tx/media/presets)
"""
import os
import sys
from PIL import Image

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
for n in ("0801", "0802", "0803", "0830", "0843"):
    im = Image.open(os.path.join(src, n + ".png")).convert("RGB")
    w, h = im.size; s = min(w, h); x0, y0 = (w - s) // 2, (h - s) // 2
    im.crop((x0, y0, x0 + s, y0 + s)).resize((256, 256), Image.BOX).save(os.path.join(out, f"div2k_{n}.png"))
    print("written", os.path.join(out, f"div2k_{n}.png"))
