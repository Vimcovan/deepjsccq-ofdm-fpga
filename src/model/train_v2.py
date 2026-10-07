"""DeepJSCC-Q float training on the decoded-image cache (see prepare_cache.py).

Differences from train_float_fpga.py:
  * data comes from raw uint8 .npy memmaps (no PNG decode), validation crops
    live on the GPU; one epoch is still one random 256 crop per training image;
  * optional KL(P(C) || U(C)) regularizer of the JSAIT paper, Eq. (18)/(21);
  * optional paper architecture (--paper-arch), sigma_q counted per parameter
    update (Eq. 22), ReduceLROnPlateau(0.8, 4) as in Sec. V;
  * validation reports the measured transmit power and a "fair" PSNR where the
    noise is referenced to max(measured power, 1) instead of the nominal P=1.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import random
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader, Dataset

from deepjsccq_model import DeepJSCCQ, count_parameters, latent_to_iq


class CachedCrops(Dataset):
    def __init__(self, cache: Path, patch: int = 256):
        meta = json.loads((cache / 'index.json').read_text(encoding='utf-8'))
        self.files = [cache / e['npy'] for e in meta['train']]
        self.shapes = [e['shape'] for e in meta['train']]
        self.patch = patch
        self._open = {}

    def __len__(self):
        return len(self.files)

    def __getitem__(self, i):
        a = self._open.get(i)
        if a is None:
            a = self._open[i] = np.load(self.files[i], mmap_mode='r')
        h, w = self.shapes[i][:2]
        top, left = random.randint(0, h - self.patch), random.randint(0, w - self.patch)
        crop = a[top:top + self.patch, left:left + self.patch]
        if random.random() < 0.5:
            crop = crop[:, ::-1]
        if random.random() < 0.5:
            crop = crop[::-1]
        return torch.from_numpy(np.ascontiguousarray(crop)).permute(2, 0, 1)


def worker_init(_):
    info = torch.utils.data.get_worker_info()
    random.seed(info.seed % 2 ** 32)


def seed_all(seed):
    random.seed(seed); np.random.seed(seed); torch.manual_seed(seed); torch.cuda.manual_seed_all(seed)


def kl_to_uniform(p: torch.Tensor) -> torch.Tensor:
    p = p.float().clamp_min(1e-12)
    return (p * (p * p.numel()).log()).sum()


@torch.inference_mode()
def tx_stats(model, images, bs=25):
    """Average hard-symbol power and hard-assignment entropy (bits)."""
    model.eval(); q = model.quantizer; c = q.constellation
    power = 0.; count = 0; hist = torch.zeros(c.shape[0], device=c.device)
    for i in range(0, len(images), bs):
        x = images[i:i + bs].float().div(255) if images.dtype == torch.uint8 else images[i:i + bs]
        pairs = latent_to_iq(model.encoder(x).float()).reshape(-1, 2)
        idx = torch.cdist(pairs, c).argmin(1)
        power += c[idx].square().sum().item(); count += len(idx)
        hist += torch.bincount(idx, minlength=c.shape[0])
    p = hist / hist.sum(); nz = p[p > 0]
    return power / count, float(-(nz * nz.log2()).sum())


@torch.inference_mode()
def mse_at(model, images, snr, seed, bs=25, repeats=1):
    model.eval(); s = 0.; n = 0
    with torch.random.fork_rng(devices=[images.device] if images.is_cuda else []):
        torch.manual_seed(seed)
        for _ in range(repeats):
            for i in range(0, len(images), bs):
                x = images[i:i + bs].float().div(255) if images.dtype == torch.uint8 else images[i:i + bs]
                s += (model(x, snr) - x).square().sum().item(); n += x.numel()
    return s / n


def psnr(mse):
    return -10 * math.log10(max(mse, 1e-12))


def evaluate(model, images, snr, seed=12345):
    power, entropy = tx_stats(model, images)
    mse = mse_at(model, images, snr, seed)
    fair_snr = snr - 10 * math.log10(max(power, 1.0))
    fair = mse_at(model, images, fair_snr, seed) if power > 1.0 else mse
    return {'val_mse': mse, 'val_psnr': psnr(mse), 'tx_power': power,
            'fair_psnr': psnr(fair), 'entropy_bits': entropy}


def evaluate_kodak(model, root, snr, device, repeats=3):
    from PIL import Image
    imgs = [torch.from_numpy(np.asarray(Image.open(p).convert('RGB')).copy()).permute(2, 0, 1)
            for p in sorted(Path(root).glob('kodim*.png'))]
    # Portrait and landscape images differ in shape; evaluate one by one.
    tot = {'mse': 0., 'fair': 0., 'power': 0.}
    for k, im in enumerate(imgs):
        x = im[None].to(device)
        power, _ = tx_stats(model, x)
        fair_snr = snr - 10 * math.log10(max(power, 1.0))
        tot['mse'] += mse_at(model, x, snr, 777 + k, repeats=repeats)
        tot['fair'] += mse_at(model, x, fair_snr, 777 + k, repeats=repeats)
        tot['power'] += power
    n = len(imgs)
    return {'kodak_psnr': psnr(tot['mse'] / n), 'kodak_fair_psnr': psnr(tot['fair'] / n),
            'kodak_tx_power': tot['power'] / n, 'images': n}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cache', default='data/cache')
    ap.add_argument('--kodak', default='data/Kodak')
    ap.add_argument('--output-dir', required=True)
    ap.add_argument('--epochs', type=int, default=200)
    ap.add_argument('--batch-size', type=int, default=8)
    ap.add_argument('--effective-batch-size', type=int, default=16)
    ap.add_argument('--workers', type=int, default=6)
    ap.add_argument('--lr', type=float, default=2e-4)
    ap.add_argument('--beta2', type=float, default=0.999)
    ap.add_argument('--plateau', action='store_true', help='ReduceLROnPlateau(factor=0.8) on val MSE')
    ap.add_argument('--plateau-patience', type=int, default=4, help='epochs without improvement (paper: 4)')
    ap.add_argument('--kl-lambda', type=float, default=0.0)
    ap.add_argument('--paper-arch', action='store_true')
    ap.add_argument('--sigma-count', choices=['micro', 'update'], default='micro',
                    help="sigma_q step counter: 'update' = optimizer updates (Eq. 22), 'micro' = legacy per mini-batch")
    ap.add_argument('--snr-db', type=float, default=10.0)
    ap.add_argument('--seed', type=int, default=20260928)
    ap.add_argument('--no-amp', action='store_true')
    ap.add_argument('--channels-last', action='store_true')
    ap.add_argument('--resume', default='')
    args = ap.parse_args()
    if args.effective_batch_size % args.batch_size:
        raise ValueError('effective-batch-size must be a multiple of batch-size')
    seed_all(args.seed)
    torch.backends.cudnn.benchmark = True
    device = torch.device('cuda')
    cache = Path(args.cache)
    train = CachedCrops(cache)
    val = torch.from_numpy(np.load(cache / 'val_center256.npy')).permute(0, 3, 1, 2).contiguous().to(device)
    tl = DataLoader(train, args.batch_size, shuffle=True, num_workers=args.workers, pin_memory=True,
                    persistent_workers=args.workers > 0, prefetch_factor=4 if args.workers else None,
                    worker_init_fn=worker_init, drop_last=False)
    model = DeepJSCCQ(32, 16, args.snr_db, quantize=True, paper=args.paper_arch).to(device)
    mf = torch.channels_last if args.channels_last else torch.contiguous_format
    model = model.to(memory_format=mf)
    opt = torch.optim.Adam(model.parameters(), lr=args.lr, betas=(0.9, args.beta2))
    sched = torch.optim.lr_scheduler.ReduceLROnPlateau(opt, factor=0.8, patience=args.plateau_patience) if args.plateau else None
    amp = not args.no_amp
    scaler = torch.amp.GradScaler('cuda', enabled=amp)
    out = Path(args.output_dir); out.mkdir(parents=True, exist_ok=True)
    if not args.resume and (out / 'training.csv').exists():
        raise SystemExit(f'{out} already has training.csv; use --resume or a new --output-dir')
    start, best, updates, micro = 1, -1e9, 0, 0
    if args.resume:
        ck = torch.load(args.resume, map_location=device, weights_only=False)
        model.load_state_dict(ck['model']); opt.load_state_dict(ck['optimizer'])
        if sched and ck.get('scheduler'): sched.load_state_dict(ck['scheduler'])
        start, best = ck['epoch'] + 1, ck['best_fair_psnr']; updates, micro = ck['updates'], ck['micro']
        seed_all(args.seed + start)  # do not replay the data order of epochs 1..N
    (out / 'args.json').write_text(json.dumps(vars(args), indent=2), encoding='utf-8')
    print(f'params={count_parameters(model):,} train={len(train)} val={len(val)} paper_arch={args.paper_arch} '
          f'kl={args.kl_lambda}', flush=True)
    accum = args.effective_batch_size // args.batch_size
    fields = ['epoch', 'train_mse', 'train_kl', 'val_mse', 'val_psnr', 'tx_power', 'fair_psnr',
              'entropy_bits', 'lr', 'sigma_q', 'updates', 'seconds', 'data_wait_s']
    with (out / 'training.csv').open('a' if start > 1 else 'w', newline='') as f:
        wr = csv.DictWriter(f, fieldnames=fields)
        if start == 1: wr.writeheader()
        for epoch in range(start, args.epochs + 1):
            t0 = time.time(); wait = 0.; model.train(); sm = sk = 0.; cnt = 0
            opt.zero_grad(set_to_none=True)
            tw = time.time()
            for step, xb in enumerate(tl, start=1):
                wait += time.time() - tw
                micro += 1
                model.quantizer.set_update_step(updates if args.sigma_count == 'update' else micro)
                x = xb.to(device, non_blocking=True).float().div_(255).contiguous(memory_format=mf)
                with torch.autocast('cuda', enabled=amp):
                    y = model(x, args.snr_db)
                    mse = nn.functional.mse_loss(y.float(), x)
                kl = kl_to_uniform(model.quantizer.probs) if args.kl_lambda > 0 else torch.zeros((), device=device)
                loss = mse + args.kl_lambda * kl
                if not torch.isfinite(loss):
                    raise FloatingPointError(f'non-finite loss at epoch {epoch} step {step}: mse={mse.item()} kl={kl.item()}')
                scaler.scale(loss / accum).backward()
                if step % accum == 0 or step == len(tl):
                    scaler.step(opt); scaler.update(); opt.zero_grad(set_to_none=True); updates += 1
                sm += mse.item() * x.shape[0]; sk += kl.item() * x.shape[0]; cnt += x.shape[0]
                tw = time.time()
            m = evaluate(model, val, args.snr_db)
            if sched: sched.step(m['val_mse'])
            row = {'epoch': epoch, 'train_mse': sm / cnt, 'train_kl': sk / cnt, **m,
                   'lr': opt.param_groups[0]['lr'], 'sigma_q': model.quantizer.sigma_q, 'updates': updates,
                   'seconds': time.time() - t0, 'data_wait_s': wait}
            ck = {'epoch': epoch, 'model': model.state_dict(), 'optimizer': opt.state_dict(),
                  'scheduler': sched.state_dict() if sched else None, 'updates': updates, 'micro': micro,
                  'best_fair_psnr': max(best, m['fair_psnr']), 'paper_arch': args.paper_arch, 'args': vars(args)}
            torch.save(ck, out / 'latest.pt')
            if m['fair_psnr'] > best:
                best = m['fair_psnr']; torch.save(ck, out / 'best.pt')
            wr.writerow(row); f.flush()
            print(f"epoch={epoch} mse={row['train_mse']:.6f} kl={row['train_kl']:.4f} val={m['val_psnr']:.3f} "
                  f"fair={m['fair_psnr']:.3f} P={m['tx_power']:.3f} H={m['entropy_bits']:.2f} "
                  f"lr={row['lr']:.2e} sq={row['sigma_q']:.0f} t={row['seconds']:.1f}s wait={wait:.1f}s", flush=True)
    ck = torch.load(out / 'best.pt', map_location=device, weights_only=False)
    model.load_state_dict(ck['model'])
    summary = {'best_epoch': ck['epoch'], 'best_fair_psnr_val': best, **evaluate(model, val, args.snr_db),
               **evaluate_kodak(model, args.kodak, args.snr_db, device), 'params': count_parameters(model)}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
