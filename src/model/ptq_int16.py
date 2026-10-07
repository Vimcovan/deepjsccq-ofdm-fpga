"""W16A16 post-training quantization of DeepJSCC-Q with the bit-exact integer model (int_ref.py).

Steps: graph check (float backend == deepjsccq_model), calibration on training
crops, then evaluation on DIV2K-val center crops and Kodak with identical channel
noise for every variant:
  float        float encoder, float decoder, unquantized received I/Q
  float_q10    float encoder/decoder, decoder input quantized to the 12-bit Q10 receiver format
  int_enc      integer encoder + float decoder (Q10 input)
  int_dec      float encoder + integer decoder (Q10 input, uint8 output)
  int          integer encoder + integer decoder (the FPGA pair)
"""
from __future__ import annotations

import argparse
import json
import math
import random
from pathlib import Path

import numpy as np
import torch
from PIL import Image

import int_ref as IR
from deepjsccq_model import iq_to_latent
from ofdm_eval import load
from train_v2 import CachedCrops

LEV = torch.as_tensor(IR.QAM_LEVELS)


def to_q10(y):
    return torch.clamp(torch.round(y * 1024), -2048, 2047)


def symbols(idx):
    return LEV.to(idx.device, torch.float32)[idx]            # (B, N, 2)


@torch.inference_mode()
def graph_check(model, dev):
    fb = IR.FloatBackend()
    x = torch.randint(0, 256, (2, 3, 256, 256), device=dev)
    xf = x.float() / 255
    ref_idx = model.quantizer(model.encoder(xf))
    idx = IR.encode(fb, model, x)
    sym_err = float((symbols(idx).flatten(1) - ref_idx.flatten(1)).abs().max())
    y = torch.randn(2, 16, 64, 64, device=dev) * 0.5
    ref = model.decoder(y)
    out = torch.sigmoid(IR.run_stack(fb, 'dec', model.decoder.net, y))
    return {'encoder_symbol_maxdiff': sym_err, 'decoder_maxdiff': float((ref - out).abs().max())}


@torch.inference_mode()
def calibrate(model, dev, n=64, snr=10.0, seed=20260928):
    fb = IR.FloatBackend()
    ds = CachedCrops(Path('data/cache'))
    random.seed(seed); torch.manual_seed(seed)
    ids = random.sample(range(len(ds)), n)
    for i in range(0, n, 16):
        x = torch.stack([ds[j] for j in ids[i:i + 16]]).to(dev)
        idx = IR.encode(fb, model, x)
        y = symbols(idx)
        y = y + torch.randn_like(y) * math.sqrt(10 ** (-snr / 10) / 2)
        q = iq_to_latent(to_q10(y), 16, x.shape[2] // 4, x.shape[3] // 4)
        IR.decode(fb, model, q)
    return fb.stats


class Evaluator:
    def __init__(self, model, scales, stats, dev, snr=10.0, wbits=16, abits=16):
        self.model, self.scales, self.stats, self.dev, self.snr = model, scales, stats, dev, snr
        self.wbits, self.abits = wbits, abits

    @torch.inference_mode()
    def run(self, images, sig_nseg=32, out_nseg=32, seed=777):
        """images: list of uint8 tensors (B,3,H,W) batches.  Returns pooled-MSE PSNR per variant."""
        m, dev = self.model, self.dev
        fb = IR.FloatBackend()
        ib = IR.IntBackend(self.scales, self.stats, sig_nseg, out_nseg, self.wbits, self.abits)
        acc = {k: 0.0 for k in ['float', 'float_q10', 'int_enc', 'int_dec', 'int']}
        n = 0; sym_mismatch = 0; sym_total = 0
        gen = torch.Generator(device=dev).manual_seed(seed)
        for x in images:
            x = x.to(dev)
            b, _, h, w = x.shape
            ref = x.double() / 255
            idx_f = IR.encode(fb, m, x)
            idx_i = IR.encode(ib, m, x).long()
            sym_mismatch += int((idx_f != idx_i).any(-1).sum()); sym_total += idx_f.shape[0] * idx_f.shape[1]
            noise = torch.randn(idx_f.shape, generator=gen, device=dev) * math.sqrt(10 ** (-self.snr / 10) / 2)
            yf = iq_to_latent(symbols(idx_f) + noise, 16, h // 4, w // 4)
            yi = iq_to_latent(symbols(idx_i) + noise, 16, h // 4, w // 4)
            dec_f = lambda y: torch.sigmoid(IR.run_stack(fb, 'dec', m.decoder.net, y)).double()
            outs = {
                'float': dec_f(yf),
                'float_q10': dec_f(to_q10(yf) / 1024),
                'int_enc': dec_f(to_q10(yi) / 1024),
                'int_dec': IR.decode(ib, m, to_q10(yf)) / 255,
                'int': IR.decode(ib, m, to_q10(yi)) / 255,
            }
            for k, o in outs.items():
                acc[k] += float((o - ref).square().sum())
            n += ref.numel()
        res = {k: -10 * math.log10(v / n) for k, v in acc.items()}
        res['symbol_mismatch_rate'] = sym_mismatch / sym_total
        return res, ib


def load_images(dev):
    val = torch.from_numpy(np.load('data/cache/val_center256.npy')).permute(0, 3, 1, 2).contiguous()
    val_batches = [val[i:i + 20] for i in range(0, len(val), 20)]
    kodak = [torch.from_numpy(np.asarray(Image.open(p).convert('RGB')).copy()).permute(2, 0, 1)[None]
             for p in sorted(Path('data/Kodak').glob('kodim*.png'))]
    return val_batches, kodak


def to_cpu(o):
    if isinstance(o, torch.Tensor):
        return o.detach().cpu()
    if isinstance(o, dict):
        return {k: to_cpu(v) for k, v in o.items()}
    return o


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--checkpoint', required=True)
    ap.add_argument('--out-dir', default='runs/ptq_int16')
    ap.add_argument('--headroom', type=float, default=1.25)
    ap.add_argument('--calib', type=int, default=64)
    ap.add_argument('--wbits', type=int, default=16)
    ap.add_argument('--abits', type=int, default=16)
    a = ap.parse_args()
    # TF32 convolutions (the CUDA default) deviate from float64 as much as the int16 model does;
    # keep the float reference in true float32.
    torch.backends.cudnn.allow_tf32 = False
    torch.backends.cuda.matmul.allow_tf32 = False
    dev = torch.device('cuda')
    model, epoch = load(a.checkpoint, dev)
    out = Path(a.out_dir); out.mkdir(parents=True, exist_ok=True)
    rep = {'checkpoint': a.checkpoint, 'epoch': epoch, 'headroom': a.headroom, 'wbits': a.wbits, 'abits': a.abits}
    rep['graph_check'] = graph_check(model, dev)
    print('graph check', rep['graph_check'], flush=True)
    stats = calibrate(model, dev, a.calib)
    scales = IR.scales_from_stats(stats, a.headroom, a.abits)
    print(f'calibrated {len(scales)} quantization points', flush=True)
    ev = Evaluator(model, scales, stats, dev, wbits=a.wbits, abits=a.abits)
    val, kodak = load_images(dev)
    rep['nseg_sweep_val'] = {}
    for nseg in [16, 32, 64]:
        r, _ = ev.run(val, nseg, nseg)
        rep['nseg_sweep_val'][nseg] = r
        print('val nseg', nseg, {k: round(v, 4) if isinstance(v, float) else v for k, v in r.items()}, flush=True)
    r_val, ib = ev.run(val, 32, 32)
    r_kodak, ib_k = ev.run(kodak, 32, 32)
    rep['val'], rep['kodak'] = r_val, r_kodak
    print('kodak', {k: round(v, 4) for k, v in r_kodak.items()}, flush=True)
    sat = {k: v for k, v in ib_k.saturation.items() if v}
    rep['kodak_saturation_counts'] = sat
    rep['max_abs_internal'] = {k: v for k, v in sorted(ib_k.width.items())}
    rep['max_bits_internal'] = {k: int(math.ceil(math.log2(v + 1))) + 1 for k, v in sorted(ib_k.width.items())}
    widest = sorted(rep['max_bits_internal'].items(), key=lambda kv: -kv[1])[:12]
    print('saturation on Kodak:', sat or 'none', flush=True)
    print('widest internal signals (signed bits):', widest, flush=True)
    (out / 'report.json').write_text(json.dumps(rep, indent=2, default=float), encoding='utf-8')
    (out / 'scales.json').write_text(json.dumps(scales, indent=1), encoding='utf-8')
    torch.save({'plan': to_cpu(ib.plan), 'scales': scales, 'stats': stats, 'epoch': epoch,
                'checkpoint': a.checkpoint}, out / 'plan.pt')


if __name__ == '__main__':
    main()
