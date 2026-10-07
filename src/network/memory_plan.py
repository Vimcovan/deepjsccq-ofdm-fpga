"""On-chip memory plan of the layer-pipelined DeepJSCC-Q FPGA design -> docs/memory_plan.md.

Every memory is its own instance (no sharing between layers): line buffers and delay FIFOs need one write + one read port (simple dual port); weight ROMs need
one wide read port.  Each instance is tiled onto the cheapest uniform BRAM18/BRAM36
aspect ratio; activation buffers that save the most BRAM per URAM.

  python memory_plan.py [--wbits 8 --abits 12 --fps 30 --fclk 250e6 --bram-target 100]
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import torch
from torch import nn

from deepjsccq_model import (AttentionBlock, DeepJSCCQ, ResidualBlock, ResidualBlockUpsample,
                             ResidualBlockWithStride)

PRIMS = [  # (depth, width, BRAM18 units, name)
    (16384, 1, 1, 'BRAM18 16Kx1'), (8192, 2, 1, 'BRAM18 8Kx2'), (4096, 4, 1, 'BRAM18 4Kx4'),
    (2048, 9, 1, 'BRAM18 2Kx9'), (1024, 18, 1, 'BRAM18 1Kx18'), (512, 36, 1, 'BRAM18 512x36 (SDP)'),
    (32768, 1, 2, 'BRAM36 32Kx1'), (16384, 2, 2, 'BRAM36 16Kx2'), (8192, 4, 2, 'BRAM36 8Kx4'),
    (4096, 9, 2, 'BRAM36 4Kx9'), (2048, 18, 2, 'BRAM36 2Kx18'), (1024, 36, 2, 'BRAM36 1Kx36'),
    (512, 72, 2, 'BRAM36 512x72 (SDP)')]
LUTRAM_MAX_DEPTH = 64
LUTRAM_MAX_BITS = 8192          # small ROMs become distributed ROM (~1 LUT per 64x1)
ZU5EG = {'BRAM36': 144, 'URAM': 64, 'DSP': 1248}


def bram_map(depth, width):
    best = None
    for d, w, c, name in PRIMS:
        cols, rows = math.ceil(width / w), math.ceil(depth / d)
        cand = (cols * rows * c, cols * rows, name)
        if best is None or cand[0] < best[0]:
            best = cand
    return best                               # (BRAM18 units, primitive count, primitive)


def uram_map(depth, width):
    return math.ceil(width / 72) * math.ceil(depth / 4096)


class Planner:
    def __init__(self, wbits, abits, fps, fclk, eff):
        self.wb, self.ab = wbits, abits
        self.budget = fclk / fps * eff
        self.model = DeepJSCCQ(paper=True).eval()
        self.shapes = {}
        for part in ('encoder', 'decoder'):
            for n, mod in getattr(self.model, part).named_modules():
                if isinstance(mod, (nn.Conv2d, AttentionBlock, ResidualBlock, ResidualBlockWithStride,
                                    ResidualBlockUpsample)):
                    mod.register_forward_hook(lambda mo, i, o, k=f'{part}.{n}': self.shapes.__setitem__(
                        k, (tuple(i[0].shape[1:]), tuple(o.shape[1:]))))
        with torch.no_grad():
            self.model(torch.rand(1, 3, 256, 256), 10)

    # ------------------------------------------------------------------ engines (weight ROMs)
    def p_min(self, cin, cout, k2, ho, wo):
        reads = k2 * cin * ho * wo
        return next(p for p in range(1, cout + 1) if reads * math.ceil(cout / p) <= self.budget)

    def rom(self, depth, width):
        """Mapping of a sequentially read weight ROM (depth x width bits), returned as
        (BRAM18 units, primitive count, description, mode, extra) with mode
          'lut'    : distributed ROM (small ROMs)
          'direct' : 72-bit column slices, 512-deep banks when deeper (rom_banked + XPM)
          'gear'   : bytes packed into 32-bit columns of 512 words + gearbox (weight_stream)
        """
        bits = depth * width
        if depth <= LUTRAM_MAX_DEPTH or bits <= LUTRAM_MAX_BITS:
            return (0, 0, 'LUTRAM', 'lut', {})
        # direct: slices of <= 72 bit, each ceil(depth/512) blocks of 512x72 (RAMB36) or 512x36 (RAMB18)
        banks = math.ceil(depth / 512)
        d18 = sum(banks * (2 if min(72, width - s0) > 36 else 1) for s0 in range(0, width, 72))
        direct = (d18, d18, f'{math.ceil(width / 72)} slice(s) x {banks} bank(s) of 512x72', 'direct',
                  {'bank': 512 if depth > 512 else 0})
        # gear: capacity (512 x 32 bit per BRAM18) and bandwidth (P bytes per cycle) bound
        lanes = width // self.wb
        ncol = max(math.ceil(bits / (512 * 32)), math.ceil(lanes * self.wb / 32))
        if ncol <= 10 and ncol < d18:
            wb = 4 * ncol
            offs = min(lanes, wb)
            glut = (lanes - 1 + wb) * 8 * math.ceil(offs / 4) + (lanes - 1 + wb) * 8 // 2 + 4 * wb * 8 // 8
            return (ncol, ncol, f'{ncol}x BRAM18 512x32 + gearbox', 'gear', {'ncol': ncol, 'gear_lut': glut})
        return direct

    def engine(self, name, cin, cout, k, ho, wo, note='', ops=None):
        k2 = k * k
        p = self.p_min(cin, cout, k2, ho, wo)              # just enough lanes for the frame rate
        depth, width = math.ceil(cout / p) * cin * k2, p * self.wb
        c18, n, prim, mode, extra = self.rom(depth, width)
        return {'name': name, 'ops': ops or [name], 'cin': cin, 'cout': cout, 'k': k, 'out': f'{ho}x{wo}',
                'p_min': p, 'P': p, 'groups': math.ceil(cout / p), 'depth': depth, 'width': width, 'b18': c18,
                'n': n, 'prim': prim, 'mode': mode, **extra,
                'rq_mul': 'lut' if p * 10 <= k2 * cin else 'dsp',
                'busy': k2 * cin * ho * wo * math.ceil(cout / p) / (self.budget / 0.8), 'note': note}

    def snoop(self, name, host, cin, cout, ho, wo):
        """1x1 skip conv fed by the centre tap of the host 3x3 conv's read stream."""
        g = host['groups']
        p = math.ceil(cout / g)
        depth, width = g * cin, p * self.wb
        c18, n, prim, mode, extra = self.rom(depth, width)
        return {'name': name, 'ops': [name], 'cin': cin, 'cout': cout, 'k': 1, 'out': f'{ho}x{wo}', 'p_min': p,
                'P': p, 'groups': g, 'depth': depth, 'width': width, 'b18': c18, 'n': n, 'prim': prim,
                'mode': mode, **extra, 'rq_mul': 'lut' if p * 10 <= cin * g else 'dsp',
                'busy': host['busy'], 'note': f'centre tap of {host["name"]}'}

    # ------------------------------------------------------------------ plan one chip
    def plan(self, part):
        E, B = [], []          # engines, buffers
        net = getattr(self.model, part).net

        # join FIFO depths measured in block simulation (rtl/gen/fifo_sizes.json, peak + margin)
        # replace the row-count estimates where available
        sizes_f = Path(__file__).resolve().parent / 'rtl' / 'gen' / 'fifo_sizes.json'
        sizes = json.loads(sizes_f.read_text(encoding='utf-8')) if sizes_f.exists() else {}

        def buf(name, kind, elems, bits, fifo=None):
            if fifo in sizes:
                elems, kind = sizes[fifo], kind.split(' (')[0] + ' (measured)'
            B.append({'name': name, 'kind': kind, 'elems': int(elems), 'bits': bits})

        for i, blk in enumerate(net):
            nm = f'{part[:3]}.{i}'
            (C, H, W), (Co, Ho, Wo) = self.shapes[f'{part}.net.{i}']
            a_in = 8 if (part == 'encoder' and i == 0) else self.ab
            if isinstance(blk, ResidualBlockWithStride):
                s = blk.conv1.stride[0]
                h1 = self.engine(f'{nm}.conv1', C, Co, 3, Ho, Wo, f'stride {s}')
                E.append(h1)
                E.append(self.engine(f'{nm}.conv2', Co, Co, 3, Ho, Wo))
                if isinstance(blk.skip, nn.Conv2d):
                    E.append(self.snoop(f'{nm}.skip', h1, C, Co, Ho, Wo))
                E.append(self.gdn(f'{nm}.gdn', Co, Ho, Wo))
                buf(f'{nm}.conv1 line buffer', '3x3 line buffer (3 rows)', 3 * W * C, a_in)
                buf(f'{nm}.conv2 line buffer', '3x3 line buffer (3 rows)', 3 * Wo * Co, self.ab)
                rows = 1.5 if s == 2 else 2.0
                buf(f'{nm}.skip delay', f'skip delay FIFO ({rows:g} rows)', rows * Wo * Co, self.ab, f'{nm}.out.b')
            elif isinstance(blk, ResidualBlock):
                h1 = self.engine(f'{nm}.conv1', C, Co, 3, H, W)
                E.append(h1)
                E.append(self.engine(f'{nm}.conv2', Co, Co, 3, H, W))
                if isinstance(blk.skip, nn.Conv2d):
                    E.append(self.snoop(f'{nm}.skip', h1, C, Co, H, W))
                buf(f'{nm}.conv1 line buffer', '3x3 line buffer (3 rows)', 3 * W * C, a_in)
                buf(f'{nm}.conv2 line buffer', '3x3 line buffer (3 rows)', 3 * W * Co, self.ab)
                buf(f'{nm}.skip delay', 'skip delay FIFO (2 rows)', 2 * W * min(C, Co), self.ab, f'{nm}.out.b')
            elif isinstance(blk, ResidualBlockUpsample):
                r = blk.scale
                E.append(self.engine(f'{nm}.conv+skip', C, 2 * Co * r * r, 3, H, W,
                                     'main and skip 3x3 merged (same input)', [f'{nm}.conv', f'{nm}.skip']))
                E.append(self.engine(f'{nm}.conv2', Co, Co, 3, Ho, Wo))
                E.append(self.gdn(f'{nm}.igdn', Co, Ho, Wo))
                buf(f'{nm}.conv/skip line buffer', '3x3 line buffer (3 rows)', 3 * W * C, a_in)
                if r > 1:
                    buf(f'{nm}.shuffle row (main)', 'pixel-shuffle row buffer (1 row)', Wo * Co, self.ab)
                    buf(f'{nm}.shuffle row (skip)', 'pixel-shuffle row buffer (1 row)', Wo * Co, self.ab)
                buf(f'{nm}.conv2 line buffer', '3x3 line buffer (3 rows)', 3 * Wo * Co, self.ab)
                buf(f'{nm}.skip delay', 'skip delay FIFO (1 row)', Wo * Co, self.ab, f'{nm}.out.b')
            elif isinstance(blk, AttentionBlock):
                h = C // 2
                E.append(self.engine(f'{nm}.ab0.c0', C, 2 * h, 1, H, W, 'a0.c0 and b0.c0 merged (same input)',
                                     [f'{nm}.a0.c0', f'{nm}.b0.c0']))
                for br in 'ab':
                    for u in range(3):
                        if u > 0:
                            E.append(self.engine(f'{nm}.{br}{u}.c0', C, h, 1, H, W))
                        E.append(self.engine(f'{nm}.{br}{u}.c1', h, h, 3, H, W))
                        E.append(self.engine(f'{nm}.{br}{u}.c2', h, C, 1, H, W))
                        buf(f'{nm}.{br}{u} line buffer', '3x3 line buffer (3 rows)', 3 * W * h, self.ab)
                        buf(f'{nm}.{br}{u} identity delay', 'unit identity delay FIFO (1 row)', W * C,
                            a_in if u == 0 else self.ab, f'{nm}.{br}{u}.out.b')
                E.append(self.engine(f'{nm}.b3', C, C, 1, H, W))
                buf(f'{nm} identity delay', 'attention identity delay FIFO (3 rows)', 3 * W * C, a_in, f'{nm}.out.x')
        return E, B

    def gdn(self, name, c, ho, wo):
        gb = min(15, self.wb)
        c18, n, prim, mode, extra = self.rom(c * c, gb)
        lanes = math.ceil(c * c * ho * wo / self.budget)          # gamma MACs per frame / cycles
        return {'name': name, 'ops': [name], 'cin': c, 'cout': c, 'k': 1, 'out': f'{ho}x{wo}', 'p_min': lanes, 'P': lanes,
                'groups': c, 'depth': c * c, 'width': gb, 'b18': c18, 'n': n, 'prim': prim, 'mode': mode, **extra,
                'rq_mul': '-', 'busy': 0, 'note': 'GDN gamma ROM (1 lane)'}

    def place(self, part, target):
        E, B = self.plan(part)
        for b in B:
            k_max = max(1, 72 // b['bits'])
            best = None
            for k in range(1, k_max + 1):
                d, w = math.ceil(b['elems'] / k), k * b['bits']
                c18, n, prim = bram_map(d, w)
                if best is None or c18 < best[0]:
                    best = (c18, n, prim, k, d, w)
            b.update(b18=best[0], n=best[1], prim=best[2], pack=best[3], depth=best[4], width=best[5])
            du = math.ceil(b['elems'] / k_max)
            b.update(uram=uram_map(du, k_max * b['bits']), upack=k_max, udepth=du, uwidth=k_max * b['bits'])
            b['loc'] = 'BRAM'
        bram18 = sum(e['b18'] for e in E) + sum(b['b18'] for b in B)
        for b in sorted(B, key=lambda b: -b['b18'] / (2 * b['uram'])):
            if bram18 / 2 <= target:
                break
            b['loc'] = 'URAM'; bram18 -= b['b18']
        return E, B


# ---------------------------------------------------------------------- markdown
def md_table(head, rows):
    out = ['| ' + ' | '.join(head) + ' |', '|' + '|'.join('---' for _ in head) + '|']
    out += ['| ' + ' | '.join(str(c) for c in r) + ' |' for r in rows]
    return '\n'.join(out)


def summarize(E, B):
    rom18 = sum(e['b18'] for e in E)
    act18 = sum(b['b18'] for b in B if b['loc'] == 'BRAM')
    uram = sum(b['uram'] for b in B if b['loc'] == 'URAM')
    conv = [e for e in E if 'GDN' not in e['note']]
    lanes = sum(e['P'] for e in conv)
    rq_dsp = sum(e['rq_mul'] == 'dsp' for e in conv)
    gdn_dsp = sum(e['P'] for e in E if 'GDN' in e['note'])
    lut_rom = sum(e['width'] * math.ceil(e['depth'] / 64) for e in E if e['prim'] == 'LUTRAM')
    gear_lut = sum(e.get('gear_lut', 0) for e in E)
    ser_lut = 70 * sum(e['rq_mul'] == 'lut' for e in conv)
    return {'rom_b36': rom18 / 2, 'act_b36': act18 / 2, 'b36': (rom18 + act18) / 2, 'uram': uram, 'lanes': lanes,
            'rq_dsp': rq_dsp, 'gdn_dsp': gdn_dsp, 'dsp': lanes + rq_dsp + gdn_dsp,
            'gear_lut': gear_lut, 'ser_lut': ser_lut, 'n_gear': sum(e['mode'] == 'gear' for e in E),
            'lut_rom': lut_rom, 'n_act_uram': sum(b['loc'] == 'URAM' for b in B), 'n_act': len(B),
            'n_rom': sum(e['prim'] != 'LUTRAM' for e in E), 'n_rom_lut': sum(e['prim'] == 'LUTRAM' for e in E)}


def write_doc(pl: Planner, a, path: Path):
    res = {part: pl.place(part, a.bram_target) for part in ('encoder', 'decoder')}
    S = {part: summarize(*res[part]) for part in res}
    L = []
    w = L.append
    w('# DeepJSCC-Q FPGA 片上存储器分配方案\n')
    w(f'> 由 `memory_plan.py` 自动生成（W{a.wbits}A{a.abits}，{a.fclk / 1e6:.0f} MHz，{a.fps:g} fps，'
      f'BRAM36 目标上限 {a.bram_target}）。修改位宽、帧率或规则后重新运行即可更新。数字为按原语粒度的估算，'
      '最终以 Vivado 综合/实现报告为准。\n')

    w('## 1. 结论\n')
    rows = []
    for part, name in (('encoder', '编码器芯片'), ('decoder', '解码器芯片')):
        s = S[part]
        rows.append([name, f"{s['rom_b36']:.1f}", f"{s['act_b36']:.1f}", f"**{s['b36']:.1f} / {ZU5EG['BRAM36']}**",
                     f"**{s['uram']} / {ZU5EG['URAM']}**",
                     f"**{s['dsp']} / {ZU5EG['DSP']}** ({s['lanes']} + {s['rq_dsp']} + {s['gdn_dsp']})",
                     f"~{s['gear_lut'] + s['lut_rom'] + s['ser_lut']:,}"])
    w(md_table(['芯片', '权重 ROM (BRAM36)', '激活缓冲 (BRAM36)', 'BRAM36 合计', 'URAM',
                'DSP (乘累加 + 重量化 + GDN)', 'LUT 估计 (转换器 + LUT ROM + 串行乘法)'], rows))
    w('\n两片 ZU5EG 均可放下，并为 PHY（接收机 FFT、LTS 缓存等）保留约 '
      f'{ZU5EG["BRAM36"] - a.bram_target} 块 BRAM36。DSP 已包括全部卷积乘累加、用 DSP 的重量化乘法和 GDN 的通道求和；'
      '残差加、注意力门控、sigmoid、x²、IGDN 的乘法数据率低，一律用多周期 LUT 乘法器（每个约 70 LUT，尚未计入上表）；'
      '行缓存的字地址用计数器维护，不占 DSP。\n')

    w('## 2. 设计前提\n')
    w(f'- 数值格式：权重 int{a.wbits}（逐输出通道缩放），激活 int{a.abits}（逐张量缩放），GDN γ 为 {min(15, a.wbits)} 位无符号。'
      '选择理由：权重 ROM 是解码器芯片 BRAM 的最大消耗，降到 8 位收益最大；激活保持 12 位，PTQ 损失仅约 0.05 dB（W8A8 损失约 2 dB）。')
    w(f'- 架构：逐层流水，每层（每个卷积引擎）独立硬件；{a.fclk / 1e6:.0f} MHz 下每帧 {a.fclk / a.fps:,.0f} 个周期，'
      f'每层读数时间不超过帧时间的 {a.eff:.0%}。')
    w('- 卷积引擎：**每周期读 1 个激活**，广播给 P 路乘法器，P 路分别计算 P 个输出通道，每路每周期读 1 个权重；'
      '输出通道分 ⌈Cout/P⌉ 组，每组把 k×k×Cin 的窗口重读一遍。')
    w('- 数据排列：NHWC，特征图按像素、通道顺序流动。\n')

    w('## 3. 端口规则：为什么不同层不共用存储器\n')
    w(md_table(['存储器', '每周期端口需求', '模式', '跨层共用'], [
        ['3×3 行缓冲、延迟 FIFO、PixelShuffle 行缓冲', '1 写 + 1 读', '简单双口 (SDP)', '不可以：两个端口都已占用'],
        ['网络 AXI-Stream', 'valid/ready 反压', '接口约定', 'PHY 负责突发缓存'],
        ['权重 ROM', '1 读（宽字，一次读出 P 个权重）', 'SDP，可用 512×72 宽字模式', '可以但不划算（见下）'],
    ]))
    w('\n- 权重 ROM 只读，理论上可以让两层分别使用真双口 (TDP) 的两个读口；但 TDP 模式下 BRAM36 每个端口最宽 36 位，'
      '失去 512×72 宽字模式。实测按两层共用一块计算，W8 权重 ROM 反而从 64.5/92 块增加到 71/97 块 BRAM36（编码器/解码器）。'
      '**因此所有存储器都独立实例化。**')
    w('- 12 位激活按每 72 位字 6 个打包，而 BRAM 字节写使能为 9 位一组，不能单独写入一个 12 位元素：'
      '写入端按 NHWC 顺序**攒满 6 个元素后整字写入**（写入本身是顺序的，不需要读-改-写）；读出端读整字后用 6 选 1 选择器取元素。\n')

    w('## 4. 各类存储器的组织方式\n')
    w('### 4.1 权重 ROM（每个卷积引擎一个）\n')
    w('- 字宽 = P × W 位（一次读出 P 路的权重），深度 = ⌈Cout/P⌉ × Cin × k²，按"组 → 窗口位置 → 输入通道"顺序存放。')
    w('- **P 取刚好满足帧率的最小值 P_min**（读占用 ≤ 帧时间的 80%），不为存储器对齐而加大 P。')
    w('- 权重 ROM 只按地址顺序读取，所以存储形状与 P 无关。每个引擎在三种映射中取 BRAM 最少者（相同时取直接映射）：')
    w(f'  - **LUT**：深度 ≤ {LUTRAM_MAX_DEPTH} 或容量 ≤ {LUTRAM_MAX_BITS // 1024} Kb，分布式 ROM（约每 64 深×1 位 1 个 LUT）；')
    w('  - **直接映射**：按 9 路（72 位）切片，深度超过 512 时按 512 分段（`rom_banked`），每段一个 XPM 简单双口块'
      '（512×72 = 1 个 RAMB36，≤36 位 = 1 个 RAMB18）；')
    w('  - **位宽转换器**（`weight_stream`）：权重按字节紧密存入 N 列 512×32（每列 1 个 RAMB18），'
      'N = max(⌈容量/16 Kb⌉, ⌈P/4⌉)；读出后经字 FIFO + 残余窗口转换为每周期 P 字节。')
    w('- 残差块中的 1×1 旁路卷积（输入与 3×3 主卷积相同）不单独读行缓冲：**在主卷积读数流中截取窗口中心抽头**，'
      '其并行路数取 ⌈Cout_skip / 主卷积组数⌉，ROM 深度 = 主卷积组数 × Cin。')
    w('- 读同一输入的卷积**合并为一个引擎**（输出通道拼接）：上采样块的主路和旁路 3×3 卷积；'
      '注意力块两个分支的第一个 1×1 卷积（a0.c0 与 b0.c0）。')
    w('- 重量化乘法：当 P×10 ≤ k²×Cin（一次遍历的 P 个输出能以 10 周期间隔依次完成）时用基 4 串行 LUT 乘法器，'
      '否则用 1 个 DSP。')
    w('- GDN/IGDN 的 γ 矩阵（C×C）单独一个 1 路 ROM。偏置、重量化参数（pre/M/sh）、sigmoid 分段系数都按通道或按段存放，'
      '容量很小，放 LUTRAM 或寄存器。\n')
    w('### 4.2 激活缓冲\n')
    w('- **3×3 行缓冲**：3 行环形缓冲（W × Cin × 3 个元素）。由于窗口逐元素读取，需要同时保存正在写入的一行。')
    w('- **旁路延迟 FIFO**：长度等于主路延迟：普通残差块 2 行，步长 2 的残差块 1.5 个输出行，上采样块 1 个输出行，'
      '注意力块恒等支路 3 行，注意力残差单元 1 行。')
    w('- **PixelShuffle 行缓冲**：放大 2 倍时，主路和旁路各缓存 1 个输出行。')
    w('- 1×1 卷积的输入只需缓存当前像素的 Cin 个元素（每组重读一次），放 LUTRAM/寄存器，未计入下表。')
    w('- 打包：每个缓冲在"每字 1..⌊72/位宽⌋ 个元素"中选最省 BRAM 的打包方式；放入 URAM 时一律按 ⌊72/位宽⌋ 个打包。\n')
    w('### 4.3 网络接口\n')
    w('- 编码器输出 AXI-Stream：每拍一个 64-QAM 符号，tdata[23:0] = {Q[11:0], I[11:0]}，Q10 补码；PHY 负责突发缓存。')
    w('- 解码器输入同样是 24 位 {Q,I} 符号流，网络模块拆成 NHWC 的 I、Q 元素；两端支持 valid/ready 反压。\n')
    w('### 4.4 URAM 分配规则\n')
    w(f'1. 若 BRAM36 合计超过 {a.bram_target}，按"每个 URAM 能省下的 BRAM 数"从大到小，'
      '把激活缓冲挪进 URAM（每个缓冲独占，不与其它层共用），直到不超过上限。\n2. 权重 ROM 全部留在 BRAM（宽字模式效率更高）。\n')

    for part, title in (('encoder', '编码器芯片'), ('decoder', '解码器芯片')):
        E, B = res[part]
        s = S[part]
        w(f'## {5 if part == "encoder" else 6}. {title}明细\n')
        w(f'BRAM36：权重 ROM {s["rom_b36"]:.1f} + 激活缓冲 {s["act_b36"]:.1f} = **{s["b36"]:.1f}**；URAM **{s["uram"]}**；'
          f'DSP {s["dsp"]}（乘累加 {s["lanes"]}、重量化 {s["rq_dsp"]}、GDN {s["gdn_dsp"]}）；'
          f'位宽转换器 {s["n_gear"]} 个（约 {s["gear_lut"]:,} LUT）；LUT ROM {s["n_rom_lut"]} 个（约 {s["lut_rom"]:,} LUT）。\n')
        w('### 权重 ROM 与并行度\n')
        w(md_table(['引擎', 'Cin→Cout', 'k', '输出尺寸', '**P**', '组数', '读占用', 'ROM 深×宽 (bit)', '映射', 'BRAM36',
                    '重量化', '备注'],
                   [[e['name'], f"{e['cin']}→{e['cout']}", e['k'], e['out'], f"**{e['P']}**", e['groups'],
                     f"{e['busy']:.0%}" if e['busy'] else '-', f"{e['depth']}×{e['width']}",
                     e['prim'], f"{e['b18'] / 2:g}", e['rq_mul'], e['note']]
                    for e in E]))
        w('\n### 激活缓冲\n')
        rows = []
        for b in B:
            if b['loc'] == 'URAM':
                phys = f"{b['udepth']}×{b['uwidth']}（每字 {b['upack']} 个）"
                mapping, cnt = f"{b['uram']}× URAM 4K×72", f"{b['uram']} URAM"
            else:
                phys = f"{b['depth']}×{b['width']}（每字 {b['pack']} 个）"
                mapping, cnt = f"{b['n']}× {b['prim']}", f"{b['b18'] / 2:g} BRAM36"
            rows.append([b['name'], b['kind'], f"{b['elems']:,}", b['bits'], phys, mapping, f"**{b['loc']}**", cnt])
        w(md_table(['缓冲', '类型', '元素数', '位宽', '物理深×宽 (bit)', '映射', '位置', '占用'], rows))
        w('')

    w('## 7. 需要在 RTL 与综合阶段确认的事项\n')
    w('- 行缓冲/FIFO 用 `ram_style` 推断（已验证）；块 RAM 权重 ROM 用 `xpm_memory_sdpram`（写口关闭）：'
      '推断出的只读 ROM 是单口的（最宽 1K×36）且深度会取整到 2 的幂，只有简单双口 XPM 能按实际深度映射到 512×72。')
    w('- 512×72 宽字模式只在简单双口下可用；行缓冲和 FIFO 的写端需要"攒字"逻辑（见第 3 节）。')
    w('- BRAM/URAM 输出寄存器（DOA_REG/DOB_REG、URAM 流水寄存器）在 250 MHz 下建议全部打开，读延迟据此计入各引擎的流水。')
    w('- 本表未计入：PHY 部分的存储、1×1 卷积的像素缓冲、偏置/重量化参数、sigmoid 系数（均为 LUTRAM/寄存器级别），'
      '以及跨时钟域 FIFO。')
    w('- 如需进一步减少 BRAM：可把更多激活缓冲挪到 URAM（修改 `--bram-target` 后重新生成本文档）；'
      '权重 ROM 需要上电初值，不能放 URAM。')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('\n'.join(L) + '\n', encoding='utf-8')
    return S


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--wbits', type=int, default=8)
    ap.add_argument('--abits', type=int, default=12)
    ap.add_argument('--fps', type=float, default=30)
    ap.add_argument('--fclk', type=float, default=250e6)
    ap.add_argument('--eff', type=float, default=0.8)
    ap.add_argument('--bram-target', type=float, default=100)
    ap.add_argument('--out', default='docs/memory_plan.md')
    a = ap.parse_args()
    pl = Planner(a.wbits, a.abits, a.fps, a.fclk, a.eff)
    S = write_doc(pl, a, Path(a.out))
    for part, s in S.items():
        print(part, {k: v for k, v in s.items()})


if __name__ == '__main__':
    main()
