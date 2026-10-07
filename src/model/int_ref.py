"""Bit-exact integer reference model of DeepJSCC-Q (paper architecture) for the FPGA port.

One graph description (``encode`` / ``decode``) runs on two backends:
  * FloatBackend - float arithmetic identical to deepjsccq_model; records the
    calibration statistics of every quantization point;
  * IntBackend   - the integer datapath the RTL implements.  Tensors are integers
    carried in float64 (exact below 2^53, asserted), with a per-tensor real scale.

Numeric contract (W16A16, every multiplier operand fits a DSP48E2 27x18 signed):
  activations      int16, per-tensor scale (not restricted to powers of two)
  weights          int16, per-output-channel scale; bias at accumulator scale
  accumulator      <= 48 bit signed
  requantization   q = sat16(rsr(sat27(rsr(acc, pre)) * M, sh)), M < 2^17
  add              q = sat16(rsr(qa * Ma + qb * Mb, sh)), optional ReLU
  LeakyReLU(1/128) on the accumulator: acc < 0 -> rsr(acc, 7)
  rsr(v, k)        round-half-up arithmetic right shift: floor((v + 2^(k-1)) / 2^k)
  GDN / IGDN       D = (beta_q + sum_j gamma_q * rsr(x_j^2, 4)) * 2^L,
                   r = isqrt(D) (digit recurrence, floor);
                   GDN: t = sign(x) * floor(|x| * 2^F / r) then requant;
                   IGDN: requant(x * r)
  sigmoid          piecewise linear on |z| in [0, 8), Q3.12 argument, output Q0.16
                   in [0, 65536]; sigma(-z) = 1 - sigma(z); |z| >= 8 -> 1
  attention gate   out = x + rsr(a * g, 16)
  output pixel     clamp(rsr(g * 255, 16), 0, 255)
  QAM decision     per-axis integer threshold compare -> level index 0..7
  decoder input    receiver output, signed 12-bit Q10
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
import torch
import torch.nn.functional as F
from torch import Tensor, nn

from deepjsccq_model import (latent_to_iq, iq_to_latent, AttentionBlock, GDN, ResidualBlock, ResidualBlockUpsample,
                             ResidualBlockWithStride, ResidualUnit)

EXACT = 2.0 ** 53
QAM_LEVELS = np.array([-7., -5., -3., -1., 1., 3., 5., 7.]) / math.sqrt(42.0)
QAM_THRESH = np.array([-6., -4., -2., 0., 2., 4., 6.]) / math.sqrt(42.0)


# --------------------------------------------------------------------------- helpers
def rsr(v: Tensor, k) -> Tensor:
    """Round-half-up arithmetic shift right by k (k may be a tensor, k < 0 = left shift)."""
    k = torch.as_tensor(k, dtype=torch.float64, device=v.device)
    left = v * torch.pow(2.0, -k.clamp(max=0))
    kk = k.clamp(min=0)
    return torch.where(kk > 0, torch.floor((left + torch.pow(2.0, kk - 1)) / torch.pow(2.0, kk)), left)


def sat(v: Tensor, bits: int) -> Tensor:
    lim = 2.0 ** (bits - 1)
    return v.clamp(-lim, lim - 1)


def isqrt(d: Tensor) -> Tensor:
    r = torch.floor(torch.sqrt(d))
    r = r - (r * r > d).double()
    return r + ((r + 1) * (r + 1) <= d).double()


def requant_params(ratio, amax: float = 32767.0):
    """acc * ratio -> activation as satA(rsr(sat27(rsr(acc, pre)) * M, sh)); M < 2^17."""
    ratio = np.atleast_1d(np.asarray(ratio, dtype=np.float64))
    lim = amax / ratio                                  # |acc| that maps to full scale
    pre = np.maximum(0, np.ceil(np.log2(lim)) - 25).astype(np.int64)
    rp = ratio * 2.0 ** pre
    sh = np.floor(np.log2((2 ** 17 - 1) / rp)).astype(np.int64)
    m = np.round(rp * 2.0 ** sh).astype(np.int64)
    assert (m < 2 ** 17).all() and (m >= 2 ** 15).all(), m
    return pre, m, sh


def add_params(ra: float, rb: float):
    sh = int(np.floor(np.log2((2 ** 17 - 1) / max(ra, rb))))
    return int(round(ra * 2 ** sh)), int(round(rb * 2 ** sh)), sh


def sigmoid_pwl_table(nseg: int):
    ob = 15 - int(math.log2(nseg))                      # offset bits of the Q3.12 argument
    h = 8.0 / nseg
    x0 = np.arange(nseg) * h
    s0 = 1 / (1 + np.exp(-x0)); s1 = 1 / (1 + np.exp(-(x0 + h)))
    c0 = np.round(s0 * 65536).astype(np.int64)
    slope = (s1 - s0) * 65536 / 2 ** ob                 # per LSB of the offset
    s = int(np.floor(np.log2((2 ** 17 - 1) / slope.max())))
    c1 = np.round(slope * 2 ** s).astype(np.int64)
    return {'nseg': nseg, 'offset_bits': ob, 'c0': c0, 'c1': c1, 'shift': s}


@dataclass
class QT:
    q: Tensor       # integer values in float64
    s: float        # real value = q * s
    name: str = ''  # tensor name in the exported graph


# --------------------------------------------------------------------------- graph
def conv_kw(c: nn.Conv2d):
    return dict(stride=c.stride, padding=c.padding)


def residual_unit(B, name, u: ResidualUnit, x):
    body = u.body
    h = B.conv(f'{name}.c0', x, body[0], 'relu')
    h = B.conv(f'{name}.c1', h, body[2], 'relu')
    h = B.conv(f'{name}.c2', h, body[4], None)
    return B.add(f'{name}.out', h, x, relu=True)


def attention(B, name, blk: AttentionBlock, x):
    a = x
    for i, u in enumerate(blk.a):
        a = residual_unit(B, f'{name}.a{i}', u, a)
    b = x
    for i in range(3):
        b = residual_unit(B, f'{name}.b{i}', blk.b[i], b)
    b = B.conv(f'{name}.b3', b, blk.b[3], None)
    return B.gate(f'{name}.out', x, a, B.sigmoid(f'{name}.sig', b))


def res_block(B, name, blk: ResidualBlock, x):
    assert blk.act_before_add, 'integer model implements the paper (act-before-add) block'
    h = B.conv(f'{name}.conv1', x, blk.conv1, 'leaky')
    h = B.conv(f'{name}.conv2', h, blk.conv2, 'leaky')
    s = B.conv(f'{name}.skip', x, blk.skip, None) if isinstance(blk.skip, nn.Conv2d) else x
    return B.add(f'{name}.out', h, s)


def res_block_stride(B, name, blk: ResidualBlockWithStride, x):
    h = B.conv(f'{name}.conv1', x, blk.conv1, 'leaky')
    h = B.conv(f'{name}.conv2', h, blk.conv2, None)
    h = B.gdn(f'{name}.gdn', h, blk.gdn)
    s = B.conv(f'{name}.skip', x, blk.skip, None) if isinstance(blk.skip, nn.Conv2d) else x
    return B.add(f'{name}.out', h, s)


def res_block_up(B, name, blk: ResidualBlockUpsample, x):
    h = B.ps(B.conv(f'{name}.conv', x, blk.conv, 'leaky'), blk.scale)   # leaky commutes with shuffle
    h = B.conv(f'{name}.conv2', h, blk.conv2, None)
    h = B.gdn(f'{name}.igdn', h, blk.igdn)
    s = B.ps(B.conv(f'{name}.skip', x, blk.skip, None), blk.scale)
    return B.add(f'{name}.out', h, s)


def run_stack(B, prefix, net, x):
    for i, blk in enumerate(net):
        name = f'{prefix}.{i}'
        if isinstance(blk, ResidualBlockWithStride):
            x = res_block_stride(B, name, blk, x)
        elif isinstance(blk, ResidualBlockUpsample):
            x = res_block_up(B, name, blk, x)
        elif isinstance(blk, ResidualBlock):
            x = res_block(B, name, blk, x)
        elif isinstance(blk, AttentionBlock):
            x = attention(B, name, blk, x)
        else:
            raise TypeError(type(blk))
    return x


def encode(B, model, pixels: Tensor):
    """uint8 pixels (B,3,H,W) -> QAM level indices (B, N, 2) in 0..7."""
    return B.qam(run_stack(B, 'enc', model.encoder.net, B.image_in(pixels)))


def decode(B, model, rx_q10: Tensor):
    """Q10 integers (B,16,h,w) -> uint8 pixels (for the float backend: float image).
    Receiver symbols (B, N, 2) map to (B,16,h,w) with iq_to_latent."""
    return B.image_out(run_stack(B, 'dec', model.decoder.net, B.rx_in(rx_q10)))


# --------------------------------------------------------------------------- float backend
class FloatBackend:
    """Float reference identical to deepjsccq_model, recording calibration stats."""

    def __init__(self):
        self.stats = {}

    def rec(self, name, v):
        m = float(v.detach().abs().max())
        self.stats[name] = max(self.stats.get(name, 0.0), m)
        return v

    def image_in(self, px):
        return px.float() / 255.0

    def rx_in(self, q10):
        return q10.float() / 1024.0

    def conv(self, name, x, c, act):
        y = F.conv2d(x, c.weight, c.bias, **conv_kw(c))
        if act == 'relu':
            y = F.relu(y)
        elif act == 'leaky':
            y = F.leaky_relu(y, 1 / 128)
        return self.rec(name, y)

    def add(self, name, a, b, relu=False):
        y = a + b
        return self.rec(name, F.relu(y) if relu else y)

    def gdn(self, name, x, g: GDN):
        beta, gamma = g.effective()
        d = F.conv2d(x.square(), gamma.view(*gamma.shape, 1, 1), beta) + 1e-6
        self.stats[name + '.Dmax'] = max(self.stats.get(name + '.Dmax', 0.0), float(d.max()))
        y = x * torch.sqrt(d) if g.inverse else x * torch.rsqrt(d)
        return self.rec(name, y)

    def sigmoid(self, name, z):
        return torch.sigmoid(z)

    def gate(self, name, x, a, g):
        return self.rec(name, x + a * g)

    def ps(self, x, r):
        return F.pixel_shuffle(x, r)

    def qam(self, z):
        lev = torch.as_tensor(QAM_LEVELS, dtype=z.dtype, device=z.device)
        return latent_to_iq((z.unsqueeze(-1) - lev).abs().argmin(-1))

    def image_out(self, y):
        return torch.sigmoid(y)


# --------------------------------------------------------------------------- integer backend
class IntBackend:
    """Integer datapath.  ``scales`` maps every quantization point to its real scale.

    While running it records ``graph`` (ops in execution order with tensor names and
    integer parameters, for the manifest) and, if ``capture`` is a dict, the integer
    value of every named tensor (for golden vectors).
    """

    def __init__(self, scales: dict, gdn_extra: dict, sig_nseg: int = 32, out_nseg: int = 32,
                 wbits: int = 16, abits: int = 16):
        self.scales, self.gdn_extra = scales, gdn_extra
        self.sig = sigmoid_pwl_table(sig_nseg)
        self.sig_out = sigmoid_pwl_table(out_nseg)
        self.wbits, self.abits = wbits, abits
        self.wmax = 2 ** (wbits - 1) - 1               # signed weights
        self.amax = 2 ** (abits - 1) - 1               # signed activations
        self.gmax = 2 ** min(15, wbits) - 1            # unsigned GDN gamma (15 bit keeps the sum < 2^47)
        self.x2_shift = max(0, 2 * (abits - 1) - 26)   # x^2 pre-shift so it fits a 27-bit DSP port
        self.plan = {}                     # integer parameters per op name
        self.graph = []                    # ops in execution order
        self._seen = set()
        self.capture = None                # name -> integer tensor (CPU), when a dict
        self.width = {}                    # max |value| seen at internal nodes (for RTL widths)
        self.saturation = {}               # activation saturation counts per output

    # bookkeeping -------------------------------------------------------------
    def track(self, key, v):
        m = float(v.abs().max())
        assert m < EXACT, (key, m)
        self.width[key] = max(self.width.get(key, 0.0), m)

    def record(self, op):
        if op['out'] not in self._seen:
            self._seen.add(op['out']); self.graph.append(op)

    def emit(self, name, q, s):
        if self.capture is not None:
            self.capture[name] = q.detach().cpu()
        return QT(q, s, name)

    def out_act(self, name, v, s):
        """Saturate to the activation width and publish the tensor."""
        self.saturation[name] = self.saturation.get(name, 0) + int((v.abs() > self.amax).sum())
        return self.emit(name, sat(v, self.abits), s)

    def rq_plan(self, key, ratio):
        if key not in self.plan.setdefault('_rq', {}):
            pre, m, sh = requant_params(ratio, self.amax)
            self.plan['_rq'][key] = {'pre': pre, 'M': m, 'sh': sh}
        return self.plan['_rq'][key]

    def requant(self, key, acc, ratio, per_channel=False):
        p = self.rq_plan(key, ratio)
        shape = (1, -1, 1, 1) if per_channel else (-1,)
        dev = acc.device
        pre = torch.as_tensor(p['pre'], dtype=torch.float64, device=dev).view(shape)
        m = torch.as_tensor(p['M'], dtype=torch.float64, device=dev).view(shape)
        sh = torch.as_tensor(p['sh'], dtype=torch.float64, device=dev).view(shape)
        a27 = sat(rsr(acc, pre), 27)
        prod = a27 * m
        self.track(key + '.acc', acc); self.track(key + '.prod', prod)
        return rsr(prod, sh)

    # graph ops -----------------------------------------------------------------
    def image_in(self, px):
        self.record({'op': 'input', 'out': 'input', 'bits': 8, 'signed': False, 'scale': 1 / 255.0})
        return self.emit('input', px.double(), 1 / 255.0)

    def rx_in(self, q10):
        self.record({'op': 'rx_input', 'out': 'rx_in', 'bits': 12, 'signed': True, 'frac_bits': 10,
                     'scale': 2.0 ** -10})
        return self.emit('rx_in', q10.double(), 2.0 ** -10)

    def conv(self, name, x: QT, c: nn.Conv2d, act):
        s_y = self.scales[name]
        if name not in self.plan:
            w = c.weight.detach().double()
            sw = (w.abs().amax(dim=(1, 2, 3)) / self.wmax).clamp_min(1e-30)
            wq = torch.round(w / sw.view(-1, 1, 1, 1))
            b = c.bias.detach().double() if c.bias is not None else torch.zeros(len(sw), dtype=torch.float64,
                                                                               device=w.device)
            bq = torch.round(b / (x.s * sw))
            self.plan[name] = {'type': 'conv', 'wq': wq, 'bq': bq, 'w_scale': sw, 'in_scale': x.s,
                               'out_scale': s_y, 'act': act, 'stride': c.stride, 'padding': c.padding}
        p = self.plan[name]
        acc = F.conv2d(x.q, p['wq'], p['bq'], **conv_kw(c))
        if act == 'relu':
            acc = acc.clamp_min(0)
        elif act == 'leaky':
            acc = torch.where(acc < 0, rsr(acc, 7), acc)
        ratio = (x.s * p['w_scale'] / s_y).cpu().numpy()
        v = self.requant(name, acc, ratio, per_channel=True)
        rq = self.plan['_rq'][name]
        self.record({'op': 'conv', 'name': name, 'in': x.name, 'out': name, 'cin': c.in_channels,
                     'cout': c.out_channels, 'k': list(c.kernel_size), 'stride': list(c.stride),
                     'pad': list(c.padding), 'act': act, 'in_scale': x.s, 'out_scale': s_y,
                     'weight': p['wq'], 'bias': p['bq'], 'rq_pre': rq['pre'], 'rq_M': rq['M'], 'rq_sh': rq['sh']})
        return self.out_act(name, v, s_y)

    def _add_core(self, name, a: QT, b: QT, relu, s_y):
        if name not in self.plan:
            ma, mb, sh = add_params(a.s / s_y, b.s / s_y)
            self.plan[name] = {'type': 'add', 'Ma': ma, 'Mb': mb, 'sh': sh, 'relu': relu,
                               'in_scales': (a.s, b.s), 'out_scale': s_y}
        p = self.plan[name]
        acc = a.q * p['Ma'] + b.q * p['Mb']
        self.track(name + '.acc', acc)
        v = rsr(acc, p['sh'])
        return (v.clamp_min(0) if relu else v), p

    def add(self, name, a: QT, b: QT, relu=False):
        s_y = self.scales[name]
        v, p = self._add_core(name, a, b, relu, s_y)
        self.record({'op': 'add', 'name': name, 'in': [a.name, b.name], 'out': name, 'Ma': p['Ma'],
                     'Mb': p['Mb'], 'sh': p['sh'], 'relu': relu, 'out_scale': s_y})
        return self.out_act(name, v, s_y)

    def gdn(self, name, x: QT, g: GDN):
        s_y = self.scales[name]
        if name not in self.plan:
            beta, gamma = (t.detach().double() for t in g.effective())
            beta = beta + 1e-6
            sg = float(gamma.max()) / self.gmax                   # gamma: unsigned, <= 15 bit
            gq = torch.round(gamma / sg)
            s_d = x.s ** 2 * 2 ** self.x2_shift * sg              # x^2 pre-shifted to <= 26 bits
            bq = torch.round(beta / s_d)
            dmax = self.gdn_extra[name + '.Dmax'] / s_d * 4       # calibrated max, 4x margin
            lsh = 2 * int(math.floor((46 - math.log2(dmax)) / 2))  # even shift keeps sqrt exact in scale
            s_dl = s_d * 2.0 ** -lsh                              # real D = D_int * s_dl
            p = {'type': 'igdn' if g.inverse else 'gdn', 'gamma_q': gq, 'beta_q': bq, 'gamma_scale': sg,
                 'x2_shift': self.x2_shift, 'L': lsh, 'in_scale': x.s, 'out_scale': s_y}
            if g.inverse:
                p['ratio'] = x.s * math.sqrt(s_dl) / s_y
            else:
                rmin = math.sqrt(float(bq.min()) * 2.0 ** lsh)    # D >= beta: guaranteed lower bound
                fb = int(math.floor(25 - math.log2(self.amax) + math.log2(rmin)))
                p['F'] = fb
                p['ratio'] = x.s * 2.0 ** -fb / math.sqrt(s_dl) / s_y
            self.plan[name] = p
        p = self.plan[name]
        x2 = rsr(x.q * x.q, self.x2_shift)                        # <= 2^26
        acc = F.conv2d(x2, p['gamma_q'].view(*p['gamma_q'].shape, 1, 1)) + p['beta_q'].view(1, -1, 1, 1)
        d = acc * 2.0 ** p['L'] if p['L'] >= 0 else rsr(acc, -p['L'])
        self.track(name + '.D', d)
        assert float(d.max()) < 2 ** 47, (name, float(d.max()))
        r = isqrt(d)
        self.track(name + '.sqrt', r)
        if g.inverse:
            v = self.requant(name, x.q * r, p['ratio'])
        else:
            num = x.q.abs() * 2.0 ** p['F']
            t = torch.floor(num / r)
            t = t - (t * r > num).double()
            t = t + ((t + 1) * r <= num).double()
            t = torch.sign(x.q) * t
            self.track(name + '.quot', t)
            v = self.requant(name, t, p['ratio'])
        rq = self.plan['_rq'][name]
        self.record({'op': p['type'], 'name': name, 'in': x.name, 'out': name,
                     'channels': int(p['gamma_q'].shape[0]), 'x2_shift': p['x2_shift'], 'L': p['L'],
                     'F': p.get('F'), 'gamma': p['gamma_q'], 'beta': p['beta_q'],
                     'rq_pre': int(rq['pre'][0]), 'rq_M': int(rq['M'][0]), 'rq_sh': int(rq['sh'][0]),
                     'in_scale': x.s, 'out_scale': s_y})
        return self.out_act(name, v, s_y)

    def _sigmoid_pos(self, u, s, tab, key):
        """Q0.16 sigmoid of |z| = u * s (u >= 0 integer)."""
        if key not in self.plan:
            ratio = s * 2 ** 12                         # argument to Q3.12
            sh = int(np.floor(np.log2((2 ** 17 - 1) / ratio)))
            self.plan[key] = {'type': 'sigmoid', 'to_q312': {'M': int(round(ratio * 2 ** sh)), 'sh': sh}, **tab}
        p = self.plan[key]
        v = rsr(u * p['to_q312']['M'], p['to_q312']['sh'])
        big = v >= 2 ** 15
        v = v.clamp(max=2 ** 15 - 1)
        seg = torch.floor(v / 2 ** tab['offset_bits'])
        off = v - seg * 2 ** tab['offset_bits']
        c0 = torch.as_tensor(tab['c0'], dtype=torch.float64, device=u.device)[seg.long()]
        c1 = torch.as_tensor(tab['c1'], dtype=torch.float64, device=u.device)[seg.long()]
        g = c0 + rsr(c1 * off, tab['shift'])
        return torch.where(big, torch.full_like(g, 65536.0), g.clamp(0, 65536))

    def sigmoid(self, name, z: QT):
        gp = self._sigmoid_pos(z.q.abs(), z.s, self.sig, name)
        g = torch.where(z.q < 0, 65536 - gp, gp)                  # Q0.16 gate in [0, 65536]
        p = self.plan[name]
        self.record({'op': 'sigmoid', 'name': name, 'in': z.name, 'out': name, 'table': 'sigmoid_pwl',
                     'to_q312_M': p['to_q312']['M'], 'to_q312_sh': p['to_q312']['sh'],
                     'out_bits': 17, 'out_signed': False, 'out_frac_bits': 16})
        return self.emit(name, g, 2.0 ** -16)

    def gate(self, name, x: QT, a: QT, g: QT):
        s_y = self.scales[name]
        ag = QT(rsr(a.q * g.q, 16), a.s)
        v, p = self._add_core(name, x, ag, False, s_y)
        self.record({'op': 'gate', 'name': name, 'in': [x.name, a.name, g.name], 'out': name,
                     'Ma': p['Ma'], 'Mb': p['Mb'], 'sh': p['sh'], 'out_scale': s_y})
        return self.out_act(name, v, s_y)

    def ps(self, x: QT, r):
        out = f'{x.name}.ps{r}'
        self.record({'op': 'pixel_shuffle', 'in': x.name, 'out': out, 'factor': r})
        return self.emit(out, F.pixel_shuffle(x.q, r), x.s)

    def qam(self, z: QT):
        thr = np.floor(QAM_THRESH / z.s).astype(np.int64)
        th = torch.as_tensor(thr, dtype=torch.float64, device=z.q.device)
        self.plan['qam'] = {'type': 'qam', 'thresholds_int': thr, 'in_scale': z.s}
        self.record({'op': 'qam', 'in': z.name, 'out': 'latent_idx', 'thresholds': thr,
                     'pairing': 'NHWC stream order: symbol = channels (2j, 2j+1) of one pixel = (I, Q)'})
        idx = latent_to_iq((z.q.unsqueeze(-1) > th).sum(-1))
        if self.capture is not None:
            self.capture['latent_idx'] = idx.detach().cpu()
        return idx

    def image_out(self, y: QT):
        gp = self._sigmoid_pos(y.q.abs(), y.s, self.sig_out, 'out.sig')
        g = torch.where(y.q < 0, 65536 - gp, gp)
        px = rsr(g * 255, 16).clamp(0, 255)
        p = self.plan['out.sig']
        self.record({'op': 'sigmoid_out', 'in': y.name, 'out': 'output', 'table': 'sigmoid_pwl_out',
                     'to_q312_M': p['to_q312']['M'], 'to_q312_sh': p['to_q312']['sh'], 'out_bits': 8})
        if self.capture is not None:
            self.capture['output'] = px.detach().cpu()
        return px


def scales_from_stats(stats: dict, headroom: float = 1.25, abits: int = 16, overrides=None) -> dict:
    """Per-tensor scale = headroom * calibrated max / activation max; ``overrides`` maps a
    tensor name to its own headroom."""
    amax = 2 ** (abits - 1) - 1
    overrides = overrides or {}
    return {k: max(v, 1e-8) * overrides.get(k, headroom) / amax
            for k, v in stats.items() if not k.endswith('.Dmax')}
