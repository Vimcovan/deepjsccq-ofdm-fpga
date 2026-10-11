"""Kodak PSNR of the deployed float checkpoint, reported two ways: mean of per-image PSNR (as the error-bar plots of
the DeepJSCC-Q paper, Fig. 12) and PSNR of the pooled MSE (as data/model/manifest.json). AWGN 10 dB, 64-QAM,
several noise draws per image.

    python eval_kodak_per_image.py --kodak <dir with kodim*.png> [--ckpt data/model/checkpoint/best.pt] [--draws 10]
"""
import argparse
import glob
import os

import numpy as np
import torch
from PIL import Image

import deepjsccq_model as M

ap = argparse.ArgumentParser()
ap.add_argument('--kodak', required=True)
ap.add_argument('--ckpt', default=os.path.join(os.path.dirname(__file__), '..', '..', 'data', 'model', 'checkpoint', 'best.pt'))
ap.add_argument('--draws', type=int, default=10)
ap.add_argument('--snr', type=float, default=10.0)
a = ap.parse_args()

dev = 'cuda' if torch.cuda.is_available() else 'cpu'
ck = torch.load(a.ckpt, map_location='cpu', weights_only=False)
sd = ck.get('model', ck.get('state_dict', ck))
net = M.DeepJSCCQ(32, 16, a.snr, paper=True)
net.load_state_dict(sd)
net.eval().to(dev)
torch.manual_seed(0)
per, mses = [], []
with torch.no_grad():
    for f in sorted(glob.glob(os.path.join(a.kodak, 'kodim*.png'))):
        x = torch.from_numpy(np.asarray(Image.open(f).convert('RGB'), np.float32) / 255).permute(2, 0, 1)[None].to(dev)
        for _ in range(a.draws):
            y = net(x, a.snr).clamp(0, 1)
            y = torch.round(y * 255) / 255
            m = float(((y - x) ** 2).mean())
            mses.append(m); per.append(10 * np.log10(1 / m))
print(f'Kodak {len(per) // a.draws} images x {a.draws} draws: mean per-image PSNR {np.mean(per):.2f} dB '
      f'(std {np.std(per):.2f}), pooled-MSE PSNR {10 * np.log10(1 / np.mean(mses)):.2f} dB')
