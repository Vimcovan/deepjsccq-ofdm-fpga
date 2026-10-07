"""Decode training images once into raw uint8 .npy files for fast random crops.

PNG decoding of 2K images costs ~53 ms/image, which capped the old DataLoader at
~75 img/s while the GPU can train at 200+ img/s.  The cache holds exactly the
decoded RGB pixels (H, W, 3), so crops are bit-identical to the PNG pipeline.
The validation set is stored as its 256x256 center crops in one array.

  python prepare_cache.py --train-dirs <DIV2K_train_HR> data/Flickr2K \
      --val-dir <DIV2K_valid_HR> --out data/cache
"""
from __future__ import annotations

import argparse
import json
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

EXTS = {'.png', '.jpg', '.jpeg', '.bmp', '.webp'}


def list_images(roots):
    return sorted(p for root in roots for p in Path(root).rglob('*') if p.suffix.lower() in EXTS)


def decode(path: Path) -> np.ndarray:
    with Image.open(path) as im:
        return np.asarray(im.convert('RGB'))


def convert(job):
    src, dst = job
    dst = Path(dst)
    if not dst.exists():
        tmp = dst.with_suffix('.tmp.npy')
        np.save(tmp, decode(Path(src)))
        tmp.replace(dst)
    arr = np.load(dst, mmap_mode='r')
    return str(dst), list(arr.shape)


def center_crop(path: Path, patch: int) -> np.ndarray:
    a = decode(path)
    h, w = a.shape[:2]
    # Same rounding as torchvision CenterCrop.
    top, left = int(round((h - patch) / 2.0)), int(round((w - patch) / 2.0))
    return a[top:top + patch, left:left + patch]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--train-dirs', nargs='+', required=True)
    ap.add_argument('--val-dir', required=True)
    ap.add_argument('--out', default='data/cache')
    ap.add_argument('--patch', type=int, default=256)
    ap.add_argument('--workers', type=int, default=12)
    args = ap.parse_args()
    out = Path(args.out)
    (out / 'train').mkdir(parents=True, exist_ok=True)

    paths = list_images(args.train_dirs)
    # Prefix with the root index so equal file names from different roots cannot collide.
    root_of = {p: i for i, r in enumerate(args.train_dirs) for p in list_images([r])}
    jobs = [(str(p), str(out / 'train' / f'{root_of[p]}_{p.stem}.npy')) for p in paths]
    with ProcessPoolExecutor(args.workers) as ex:
        entries = list(ex.map(convert, jobs, chunksize=8))
    index = [{'src': s, 'npy': Path(d).relative_to(out).as_posix(), 'shape': sh}
             for (s, _), (d, sh) in zip(jobs, entries)]

    val_paths = list_images([args.val_dir])
    val = np.stack([center_crop(p, args.patch) for p in val_paths])
    np.save(out / f'val_center{args.patch}.npy', val)

    meta = {'train_dirs': args.train_dirs, 'val_dir': args.val_dir, 'patch': args.patch,
            'train': index, 'val_images': [str(p) for p in val_paths]}
    (out / 'index.json').write_text(json.dumps(meta, indent=1), encoding='utf-8')
    print(f'train images: {len(index)}  val crops: {val.shape}  -> {out}')


if __name__ == '__main__':
    main()
