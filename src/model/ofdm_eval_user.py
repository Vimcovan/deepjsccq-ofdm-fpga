"""OFDM evaluation matched to the user's MATLAB receiver (PHY_80211a.m, not included).

Channel: the 5-path TGn-style PDP of PHY_80211a.m (0..40 ns, rms delay spread ~4 ns,
i.e. almost flat Rayleigh per frame), static over the frame.  Transmitter uses a
1x 64-point IFFT with separate I/Q saturation, as in the MATLAB model.

  rx   : channel estimation (1 LTS / 2 LTS averaged) x equalizer (ZF / MMSE post-scale
         with true, LTS-difference-estimated or fixed noise variance), SNR 5/10/15 dB
  clip : I/Q saturation threshold sweep on AWGN (fixed SNR and peak-limited), and the
         overshoot after 4x interpolation (what the AD9361 DAC sees)
  final: fading + 2-LTS + MMSE(est) with the chosen clip level vs the current receiver
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
import torch

from ofdm_channel import OFDMChannel
from deepjsccq_model import latent_to_iq
from ofdm_eval import load

USER_PDP = [(0, 0.0), (10, -9.7), (20, -19.2), (30, -22.8), (40, -27.7)]
K = 16 * 64 * 64 // 2


@torch.inference_mode()
def run(model, images, channel, snr, seed=4242, repeats=8, bs=25):
    """Dataset PSNR (pooled MSE), mean per-image PSNR and 5th percentile per-image PSNR."""
    model.channel = channel
    torch.manual_seed(seed)
    per = []
    for _ in range(repeats):
        for i in range(0, len(images), bs):
            x = images[i:i + bs].float().div(255)
            per.append((model(x, snr) - x).square().flatten(1).mean(1))
    mse = torch.cat(per)
    p = -10 * torch.log10(mse)
    return {'psnr': float(-10 * torch.log10(mse.mean())), 'mean_img_psnr': float(p.mean()),
            'p5_img_psnr': float(torch.quantile(p, 0.05))}


def rms_delay_spread_ns(pdp):
    d = np.array([x[0] for x in pdp], float); p = 10 ** (np.array([x[1] for x in pdp]) / 10); p /= p.sum()
    m = (p * d).sum()
    return float(np.sqrt((p * d ** 2).sum() - m ** 2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--checkpoint', required=True)
    ap.add_argument('--cache', default='data/cache')
    ap.add_argument('--out', required=True)
    ap.add_argument('--only', nargs='*', default=['rx', 'clip', 'final'])
    a = ap.parse_args()
    dev = torch.device('cuda')
    model, epoch = load(a.checkpoint, dev)
    images = torch.from_numpy(np.load(Path(a.cache) / 'val_center256.npy')).permute(0, 3, 1, 2).contiguous().to(dev)
    res = {'checkpoint': a.checkpoint, 'epoch': epoch, 'rms_delay_spread_ns': rms_delay_spread_ns(USER_PDP)}
    ch = lambda **kw: OFDMChannel(K, oversample=1, rx_clamp=2.0, **kw).to(dev)
    comp_rms = math.sqrt(52 / 64 / 2)
    res['current_clip_db'] = 20 * math.log10(2.0 / comp_rms)  # the +-2 saturation in PHY_80211a.m
    print('rms delay spread %.2f ns, current I/Q clip = %.2f dB above per-component RMS'
          % (res['rms_delay_spread_ns'], res['current_clip_db']), flush=True)

    if 'rx' in a.only:
        rows = []
        for snr in [5, 10, 15]:
            cases = [('awgn_ref', dict(equalizer='zf', csi='perfect')),
                     ('perfect_zf', dict(pdp=USER_PDP, equalizer='zf', csi='perfect')),
                     ('perfect_mmse', dict(pdp=USER_PDP, equalizer='mmse', csi='perfect')),
                     ('ltf1_zf (current RTL)', dict(pdp=USER_PDP, equalizer='zf', csi='ltf1')),
                     ('ltf2_zf', dict(pdp=USER_PDP, equalizer='zf', csi='ltf')),
                     ('ltf2_mmse_true', dict(pdp=USER_PDP, equalizer='mmse', csi='ltf')),
                     ('ltf2_mmse_est', dict(pdp=USER_PDP, equalizer='mmse_est', csi='ltf')),
                     ('ltf2_mmse_fixed10dB', dict(pdp=USER_PDP, equalizer='mmse_fixed', mmse_var=0.1, csi='ltf')),
                     ('ltf1_mmse_est', dict(pdp=USER_PDP, equalizer='mmse_est', csi='ltf1'))]
            for name, kw in cases:
                r = {'snr_db': snr, 'case': name, **run(model, images, ch(**kw), snr)}
                rows.append(r); print('rx', r, flush=True)
        res['receiver'] = rows

    if 'clip' in a.only:
        rows = []
        ref = res['current_clip_db']
        for cr in [None, ref, 9, 8, 7, 6, 5, 4, 3]:
            c = ch(clip_db=cr, clip_mode='square', equalizer='zf', csi='perfect')
            # peak-limited: DAC full scale fixed at the clip level; SNR 10 dB at the current +-2 setting
            snr_pl = 10 + (ref - (cr if cr is not None else ref))
            r = {'clip_db': cr, 'threshold_abs': None if cr is None else comp_rms * 10 ** (cr / 20),
                 'fixed_snr10': run(model, images, c, 10, repeats=2)['psnr'],
                 'snr_peak_limited': snr_pl, 'peak_limited': run(model, images, c, snr_pl, repeats=2)['psnr']}
            if cr is not None:  # overshoot of the 4x-interpolated clipped signal over the threshold
                with torch.no_grad():
                    z = model.quantizer(model.encoder(images[:25].float().div(255)))
                    g = c.clip(c.grid(c.scramble(torch.complex(*latent_to_iq(z).unbind(-1)))))
                    t4 = OFDMChannel(K, oversample=4).to(dev).time_signal(g)
                    peak = torch.maximum(t4.real.abs(), t4.imag.abs()).amax(-1).flatten()
                    over = 20 * torch.log10(peak / r['threshold_abs'])
                r['overshoot_db_p50'] = float(over.median()); r['overshoot_db_p99'] = float(torch.quantile(over, 0.99))
            rows.append(r); print('clip', r, flush=True)
        res['clip'] = rows

    if 'final' in a.only:
        rows = []
        ref = res['current_clip_db']
        for name, kw, cr in [('current: ltf1+zf, clip +-2', dict(equalizer='zf', csi='ltf1'), ref),
                             ('proposed: ltf2+mmse_est, clip 6dB', dict(equalizer='mmse_est', csi='ltf'), 6),
                             ('proposed: ltf2+mmse_est, clip 5dB', dict(equalizer='mmse_est', csi='ltf'), 5)]:
            c = ch(pdp=USER_PDP, clip_db=cr, clip_mode='square', **kw)
            snr = 10 + (ref - cr)  # same DAC full scale / peak power for every row
            r = {'case': name, 'snr_db': snr, **run(model, images, c, snr)}
            rows.append(r); print('final', r, flush=True)
        res['final'] = rows

    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(res, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
