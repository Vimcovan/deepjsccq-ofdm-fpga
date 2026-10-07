"""Evaluate a DeepJSCC-Q checkpoint over the OFDM link model (ofdm_channel.py).

Experiments (no retraining):
  papr : per-OFDM-symbol PAPR CCDF - model symbols unscrambled / scrambled / random 64-QAM
  clip : AWGN, fixed peak power; clip ratio sweep.  SNR = PNR - CR, so clipping
         harder raises average power (SNR) at the cost of in-band distortion
  fsel : frequency-selective Rayleigh channel, ZF vs MMSE, perfect vs LTF CSI
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
import torch

from deepjsccq_model import DeepJSCCQ, latent_to_iq
from ofdm_channel import OFDMChannel


def load(ckpt, device):
    ck = torch.load(ckpt, map_location='cpu', weights_only=False)
    m = DeepJSCCQ(32, 16, 10.0, quantize=True, paper=ck.get('paper_arch', False)).to(device).eval()
    m.load_state_dict(ck['model'])
    return m, ck.get('epoch')


@torch.inference_mode()
def psnr(model, images, channel, snr, seed=4242, repeats=2, bs=25):
    model.channel = channel
    s = n = 0.
    torch.manual_seed(seed)
    for _ in range(repeats):
        for i in range(0, len(images), bs):
            x = images[i:i + bs].float().div(255)
            s += (model(x, snr) - x).square().sum().item(); n += x.numel()
    return -10 * math.log10(s / n)


@torch.inference_mode()
def latent_iq(model, images, bs=25):
    out = []
    for i in range(0, len(images), bs):
        z = model.quantizer(model.encoder(images[i:i + bs].float().div(255)))
        out.append(latent_to_iq(z))
    return torch.cat(out)


def ccdf(papr, levels=(1e-1, 1e-2, 1e-3, 1e-4)):
    v = np.sort(papr.cpu().numpy())[::-1]
    return {f'{p:g}': float(v[int(p * len(v))]) for p in levels if int(p * len(v)) >= 1}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--checkpoint', required=True)
    ap.add_argument('--cache', default='data/cache')
    ap.add_argument('--out', required=True)
    ap.add_argument('--snr-db', type=float, default=10.0)
    ap.add_argument('--pnr-db', type=float, default=22.0, help='peak-to-noise ratio for the clip sweep')
    ap.add_argument('--rx-clamp', type=float, default=2.0, help='decoder input saturation (Q10 12-bit = +-2)')
    ap.add_argument('--only', nargs='*', default=['sanity', 'papr', 'clip', 'fsel', 'chest'])
    a = ap.parse_args()
    dev = torch.device('cuda')
    model, epoch = load(a.checkpoint, dev)
    images = torch.from_numpy(np.load(Path(a.cache) / 'val_center256.npy')).permute(0, 3, 1, 2).contiguous().to(dev)
    k = 16 * 64 * 64 // 2
    res = {'checkpoint': a.checkpoint, 'epoch': epoch, 'images': len(images)}
    ofdm = lambda **kw: OFDMChannel(k, a.snr_db, rx_clamp=a.rx_clamp, **kw).to(dev)

    if 'sanity' in a.only:
        awgn = model.channel
        res['sanity'] = {'awgn': psnr(model, images, awgn, a.snr_db),
                         'ofdm_flat_noclip_zf': psnr(model, images, ofdm(equalizer='zf'), a.snr_db)}
        model.channel = awgn
        print('sanity', res['sanity'], flush=True)

    if 'papr' in a.only:
        iq = latent_iq(model, images)
        qam = model.quantizer.constellation[torch.randint(0, 64, iq.shape[:2], device=dev)]
        res['papr_ccdf_db'] = {
            'model_unscrambled': ccdf(OFDMChannel(k, scramble=False).to(dev).papr_db(iq)),
            'model_scrambled': ccdf(OFDMChannel(k).to(dev).papr_db(iq)),
            'random_64qam': ccdf(OFDMChannel(k).to(dev).papr_db(qam)),
        }
        print('papr', json.dumps(res['papr_ccdf_db']), flush=True)

    if 'clip' in a.only:
        rows = []
        for cr in [None, 12, 10, 9, 8, 7, 6, 5, 4, 3]:
            snr = a.pnr_db - (cr if cr is not None else 12)
            fixed = psnr(model, images, ofdm(clip_db=cr, equalizer='zf'), a.snr_db)
            peak = psnr(model, images, ofdm(clip_db=cr, equalizer='zf'), snr)
            rows.append({'clip_db': cr, 'psnr_at_snr10': fixed, 'snr_under_peak_limit': snr, 'psnr_peak_limited': peak})
            print('clip', rows[-1], flush=True)
        res['clip_sweep'] = rows

    if 'fsel' in a.only:
        rows = []
        for ds in [0.5, 1, 2, 4]:
            for eq in ['zf', 'mmse']:
                for csi in ['perfect', 'ltf']:
                    p = psnr(model, images, ofdm(delay_spread=ds, equalizer=eq, csi=csi), a.snr_db, repeats=4)
                    rows.append({'delay_spread_samples': ds, 'equalizer': eq, 'csi': csi, 'psnr': p})
                    print('fsel', rows[-1], flush=True)
        res['freq_selective'] = rows

    if 'chest' in a.only:
        # channel-estimation denoising: MMSE equalizer, LS vs DFT-domain fits of different length
        rows = []
        variants = [('perfect', 16), ('ltf', 16), ('ltf_ma', 3), ('ltf_ma', 5), ('ltf_dft', 16)]
        for ds in [0.5, 1, 2, 4]:
          for eq in ['zf', 'mmse']:
            for csi, taps in variants:
                ch = ofdm(delay_spread=ds, equalizer=eq, csi=csi, est_taps=taps)
                p = psnr(model, images, ch, a.snr_db, repeats=4)
                # estimation MSE on data subcarriers, averaged over random channels
                torch.manual_seed(7)
                h = ch.channel_response(4000, dev)
                var = 10 ** (-a.snr_db / 10)
                he = h + torch.randn_like(h) * math.sqrt(var / 2)
                if csi == 'ltf_dft':
                    he = he[..., ch.ltf_obs] @ ch.ltf_proj.T
                elif csi == 'ltf_ma':
                    he = he @ ch.ltf_ma.T
                elif csi == 'perfect':
                    he = h
                mse = (he - h)[..., ch.data_idx].abs().square().mean().item()
                rows.append({'delay_spread_samples': ds, 'equalizer': eq, 'csi': csi, 'est_taps': taps, 'psnr': p,
                             'est_mse_db': 10 * math.log10(mse) if mse > 0 else None})
                print('chest', rows[-1], flush=True)
        res['channel_estimation'] = rows

    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(res, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
