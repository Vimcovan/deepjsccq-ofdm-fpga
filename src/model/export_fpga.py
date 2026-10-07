"""Export the W12A12 integer DeepJSCC-Q model for RTL: parameter .mem files, golden vectors, manifest.

Layout of --out-dir:
  manifest.json                 numeric contract, tensors, ops in execution order, file index
  params/<op>.<field>.mem       one value per line, two's complement hex, fixed digit count
  golden/<image>/<tensor>.mem   every named tensor of the integer model, NHWC, one value per line

Weights are stored OHWI ([Cout][Kh][Kw][Cin]); GDN gamma as [Cout][Cin].  The latent
symbol files (latent_idx, rx_symbols) are in symbol order before the PHY scrambler.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
import torch
from PIL import Image

import int_ref as IR
from ofdm_eval import load
from deepjsccq_model import iq_to_latent
from ptq_int16 import Evaluator, calibrate, load_images, symbols, to_q10

NOISE_SEED = 20260928


def hex_lines(vals: np.ndarray, bits: int) -> str:
    vals = np.asarray(vals, dtype=np.int64).ravel()
    lo, hi = int(vals.min(initial=0)), int(vals.max(initial=0))
    assert -(1 << (bits - 1)) <= lo and hi < (1 << bits), (lo, hi, bits)   # signed or unsigned fits
    digits = (bits + 3) // 4
    masked = (vals & ((1 << bits) - 1)).tolist()
    return '\n'.join(f'{v:0{digits}X}' for v in masked) + '\n'


def write_mem(path: Path, vals, bits: int):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(hex_lines(vals, bits), encoding='ascii')
    return {'file': path.as_posix(), 'bits': bits, 'count': int(np.asarray(vals).size)}


def bits_needed(vals, signed=True):
    v = np.asarray(vals, dtype=np.int64)
    m = int(np.abs(v).max(initial=0))
    return max(1, m.bit_length()) + (1 if signed else 0)


def nhwc(t: torch.Tensor) -> np.ndarray:
    a = t.numpy().astype(np.int64)
    return a.transpose(0, 2, 3, 1) if a.ndim == 4 else a


def export_params(ib: IR.IntBackend, root: Path, rel: Path):
    ops = []
    pdir = root / 'params'
    for op in ib.graph:
        o = {k: v for k, v in op.items() if k not in ('weight', 'bias', 'gamma', 'beta', 'rq_pre', 'rq_M', 'rq_sh',
                                                       'thresholds')}
        name = op.get('name', op['out'])
        if op['op'] == 'conv':
            w = op['weight'].cpu().numpy().astype(np.int64).transpose(0, 2, 3, 1)      # OIHW -> OHWI
            b = op['bias'].cpu().numpy().astype(np.int64)
            assert bits_needed(b) <= 48, name
            o['files'] = {
                'weight': write_mem(pdir / f'{name}.weight.mem', w, ib.wbits) | {'layout': 'OHWI', 'signed': True},
                'bias': write_mem(pdir / f'{name}.bias.mem', b, 48) | {'signed': True, 'scale': 'accumulator'},
                'rq_pre': write_mem(pdir / f'{name}.rq_pre.mem', op['rq_pre'], 8) | {'signed': False},
                'rq_M': write_mem(pdir / f'{name}.rq_M.mem', op['rq_M'], 17) | {'signed': False},
                'rq_sh': write_mem(pdir / f'{name}.rq_sh.mem', op['rq_sh'], 8) | {'signed': True},
            }
        elif op['op'] in ('gdn', 'igdn'):
            g = op['gamma'].cpu().numpy().astype(np.int64)
            b = op['beta'].cpu().numpy().astype(np.int64)
            gb = min(15, ib.wbits)
            assert bits_needed(b, signed=False) <= 48 and op['L'] >= 0 and (op['F'] is None or op['F'] >= 0), name
            o['files'] = {
                'gamma': write_mem(pdir / f'{name}.gamma.mem', g, gb) | {'layout': '[Cout][Cin]', 'signed': False},
                'beta': write_mem(pdir / f'{name}.beta.mem', b, 48) | {'signed': False},
            }
            o['rq'] = {'pre': op['rq_pre'], 'M': op['rq_M'], 'sh': op['rq_sh']}
        elif op['op'] == 'qam':
            o['thresholds'] = [int(t) for t in op['thresholds']]
        ops.append(o)
    tables = {}
    for key, tab in (('sigmoid_pwl', ib.sig), ('sigmoid_pwl_out', ib.sig_out)):
        tables[key] = {'nseg': tab['nseg'], 'offset_bits': tab['offset_bits'], 'shift': tab['shift'],
                       'c0': write_mem(pdir / f'{key}.c0.mem', tab['c0'], 17) | {'signed': False},
                       'c1': write_mem(pdir / f'{key}.c1.mem', tab['c1'], 17) | {'signed': False}}
    rel_files(ops, root); rel_files(tables, root)
    return ops, tables


def rel_files(obj, root):
    """Make every 'file' entry relative to the export root."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == 'file':
                obj[k] = Path(v).relative_to(root).as_posix()
            else:
                rel_files(v, root)
    elif isinstance(obj, list):
        for v in obj:
            rel_files(v, root)


def tensor_format(op, ib):
    if op['op'] == 'input':
        return 8, False
    if op['op'] == 'sigmoid':
        return 17, False
    if op['op'] == 'sigmoid_out':
        return 8, False
    if op['op'] == 'rx_input':
        return 12, True
    if op['op'] == 'qam':
        return 3, False
    return ib.abits, True


def golden_images(n_val=2):
    val = np.load('data/cache/val_center256.npy')[:n_val]
    imgs = [(f'div2k_val_{i:02d}', val[i]) for i in range(n_val)]
    k = np.asarray(Image.open('data/Kodak/kodim23.png').convert('RGB'))
    h, w = k.shape[:2]
    imgs.append(('kodim23_center256', k[(h - 256) // 2:(h + 256) // 2, (w - 256) // 2:(w + 256) // 2]))
    return imgs


@torch.inference_mode()
def run_golden(ib, model, img_hwc, dev, snr):
    ib.capture = {}
    x = torch.from_numpy(np.ascontiguousarray(img_hwc)).permute(2, 0, 1)[None].to(dev)
    idx = IR.encode(ib, model, x).long()
    gen = torch.Generator(device=dev).manual_seed(NOISE_SEED)
    noise = torch.randn(idx.shape, generator=gen, device=dev) * math.sqrt(10 ** (-snr / 10) / 2)
    q10 = to_q10(symbols(idx) + noise)                                  # (1, N, 2) receiver output
    ib.capture['rx_symbols'] = q10.detach().cpu()
    ib.capture['tx_symbols_q10'] = to_q10(symbols(idx)).detach().cpu()    # noiseless transmitter output
    IR.decode(ib, model, iq_to_latent(q10, 16, x.shape[2] // 4, x.shape[3] // 4))
    cap, ib.capture = ib.capture, None
    return cap


def memory_plan_section(a):
    """Per-engine lanes P and memory placement from memory_plan.py (see docs/memory_plan.md)."""
    from memory_plan import Planner
    pl = Planner(a.wbits, a.abits, 30, 250e6, 0.8)
    out = {'source': 'memory_plan.py (docs/memory_plan.md)', 'fclk_hz': 250e6, 'fps': 30, 'bram36_target': 100}
    for part in ('encoder', 'decoder'):
        engines, buffers = pl.place(part, 100)
        # merged engines list their ops in output-channel order ([first | second])
        out[part] = {'engines': engines, 'buffers': buffers}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--checkpoint', default='runs/long1200_paper_arch/best.pt')
    ap.add_argument('--out-dir', default='runs/fpga_export_w8a12')
    ap.add_argument('--wbits', type=int, default=8)
    ap.add_argument('--abits', type=int, default=12)
    ap.add_argument('--headroom', type=float, default=1.5)
    ap.add_argument('--override', nargs='*', default=['dec.9.igdn=2.0'], help='tensor=headroom')
    ap.add_argument('--snr-db', type=float, default=10.0)
    ap.add_argument('--plan-only', action='store_true', help='only refresh the memory_plan section of manifest.json')
    a = ap.parse_args()
    if a.plan_only:
        mf = Path(a.out_dir) / 'manifest.json'
        man = json.loads(mf.read_text(encoding='utf-8'))
        man['memory_plan'] = memory_plan_section(a)
        mf.write_text(json.dumps(man, indent=1), encoding='utf-8')
        print('memory_plan refreshed in', mf)
        return
    torch.backends.cudnn.allow_tf32 = False
    torch.backends.cuda.matmul.allow_tf32 = False
    dev = torch.device('cuda')
    root = Path(a.out_dir); root.mkdir(parents=True, exist_ok=True)
    model, epoch = load(a.checkpoint, dev)
    stats = calibrate(model, dev, 64)
    overrides = {k: float(v) for k, v in (s.split('=') for s in a.override)}
    scales = IR.scales_from_stats(stats, a.headroom, a.abits, overrides)

    # accuracy of exactly this configuration
    ev = Evaluator(model, scales, stats, dev, snr=a.snr_db, wbits=a.wbits, abits=a.abits)
    val, kodak = load_images(dev)
    acc_val, _ = ev.run(val)
    acc_kodak, ib_k = ev.run(kodak)
    print('val', {k: round(v, 4) for k, v in acc_val.items()}, flush=True)
    print('kodak', {k: round(v, 4) for k, v in acc_kodak.items()}, flush=True)
    print('saturation (Kodak):', {k: v for k, v in ib_k.saturation.items() if v} or 'none', flush=True)

    # golden vectors (these runs also record the graph)
    ib = IR.IntBackend(scales, stats, 32, 32, a.wbits, a.abits)
    golden = {}
    for img_name, img in golden_images():
        cap = run_golden(ib, model, img, dev, a.snr_db)
        files = {}
        fmt = {op['out']: tensor_format(op, ib) for op in ib.graph}
        for tname, t in cap.items():
            if tname in ('rx_symbols', 'tx_symbols_q10'):
                # PHY interface: one 24-bit {Q, I} word per symbol, Q10 two's complement
                iq = t.numpy().astype(np.int64)[0]
                word = ((iq[:, 1] & 0xFFF) << 12) | (iq[:, 0] & 0xFFF)
                name = {'rx_symbols': 'rx_iq24', 'tx_symbols_q10': 'tx_iq24'}[tname]
                files[name] = write_mem(root / 'golden' / img_name / f'{name}.mem', word, 24) | {
                    'shape': [int(iq.shape[0])], 'layout': '[symbol] {Q[23:12], I[11:0]} Q10', 'signed': False}
                if tname == 'tx_symbols_q10':
                    continue
                bits, signed = 12, True
            else:
                bits, signed = fmt[tname]
            arr = nhwc(t)
            files[tname] = write_mem(root / 'golden' / img_name / f'{tname}.mem', arr, bits) | {
                'shape': list(arr.shape[1:]) if arr.ndim == 4 else list(arr.shape[1:]),
                'layout': 'HWC' if arr.ndim == 4 else '[symbol][I,Q]', 'signed': signed}
        rel_files(files, root)
        golden[img_name] = files
        print('golden', img_name, len(files), 'tensors', flush=True)

    ops, tables = export_params(ib, root, root)
    tensors = {}
    for op in ib.graph:
        bits, signed = tensor_format(op, ib)
        t = golden[next(iter(golden))].get(op['out'])
        tensors[op['out']] = {'bits': bits, 'signed': signed, 'shape_hwc': t['shape'] if t else None,
                              'scale': op.get('out_scale', op.get('scale'))}
    manifest = {
        'model': 'DeepJSCC-Q (JSAIT 2022 architecture), C=32, Cout=16, 64-QAM',
        'memory_plan': memory_plan_section(a),
        'checkpoint': a.checkpoint, 'epoch': epoch,
        'format': {'weights': f'int{a.wbits} signed, per-output-channel scale, OHWI',
                   'activations': f'int{a.abits} signed, per-tensor scale, NHWC',
                   'mem': 'one value per line, two\'s complement hex, digits = ceil(bits/4)',
                   'golden_input': 'uint8 RGB, 256x256',
                   'channel': f'AWGN {a.snr_db} dB on the unit-power 64-QAM symbols, seed {NOISE_SEED}; '
                              'rx_symbols = receiver output Q10 (12 bit) per symbol [I,Q]',
                   'latent_pairing': 'NHWC stream order: symbol k = NHWC elements (2k, 2k+1) = channels (2j, 2j+1) '
                                     'of one pixel = (I, Q); rx_in (NHWC) is the same element sequence',
                   'latent_idx': 'per symbol [I level, Q level], level 0..7 <-> (2*level-7)/sqrt(42)',
                   'phy_interface': {
                       'word': 'AXI-Stream, one symbol per beat, tdata[23:0] = {Q[11:0], I[11:0]}, Q10 two\'s complement, '
                               'valid/ready backpressure; encoder tlast = last symbol of the frame',
                       'q10_levels': [int(v) for v in to_q10(symbols(torch.arange(8)[None, :, None]))[0, :, 0]],
                       'golden': 'golden/<image>/tx_iq24.mem (encoder output), rx_iq24.mem (decoder input)'}},
        'arithmetic': {
            'rsr(v,k)': 'k>0: (v + 2^(k-1)) >>> k (arithmetic);  k=0: v;  k<0: v << -k',
            'sat(v,n)': 'clamp to [-2^(n-1), 2^(n-1)-1]',
            'conv': 'acc = sum(x*w) + bias (<=48b); act on acc: relu -> max(acc,0), leaky -> acc<0 ? rsr(acc,7) : acc; '
                    'y = satA(rsr(sat27(rsr(acc, pre[c])) * M[c], sh[c]))',
            'add': 'y = satA(rsr(a*Ma + b*Mb, sh)); relu after the shift if relu',
            'gate': 'ag = rsr(a*g, 16); y = satA(rsr(x*Ma + ag*Mb, sh))',
            'gdn/igdn': 'x2 = rsr(x*x, x2_shift); D = (sum_j gamma[i][j]*x2_j + beta[i]) << L; r = floor(sqrt(D)); '
                        'gdn: t = sign(x)*floor(|x|*2^F / r); igdn: t = x*r; y = satA(rsr(sat27(rsr(t, pre))*M, sh))',
            'sigmoid': 'u=|z|; v = rsr(u*to_q312_M, to_q312_sh); if v >= 2^15: g=65536 else '
                       'seg = v >> offset_bits, off = v & (2^offset_bits-1), g = clamp(c0[seg] + rsr(c1[seg]*off, shift), 0, 65536); '
                       'z<0: g = 65536 - g   (g in Q0.16, 17 bit unsigned)',
            'sigmoid_out': 'g as sigmoid; pixel = clamp(rsr(g*255, 16), 0, 255)',
            'pixel_shuffle': 'out[h*r+i][w*r+j][c] = in[h][w][c*r*r + i*r + j]',
            'qam': 'per latent element: level = number of thresholds t with x > t (0..7)',
        },
        'tensors': tensors, 'ops': ops, 'sigmoid_tables': tables, 'golden': golden,
        'accuracy_db': {'val': acc_val, 'kodak': acc_kodak},
        'max_abs_internal': {k: v for k, v in sorted(ib_k.width.items())},
    }
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=1, default=lambda o: o.tolist()
                                                   if hasattr(o, 'tolist') else float(o)), encoding='utf-8')
    print('exported', len(ops), 'ops to', root, flush=True)


if __name__ == '__main__':
    main()
