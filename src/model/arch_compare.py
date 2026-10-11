"""Parameter / MAC count of the JSAIT DeepJSCC-Q layout (C = 256, four stride-2 stages) and the deployed FPGA layout
(C = 32, two stride-2 stages), both with 256x256 input and the same latent size 65,536 (= 32,768 complex symbols).

MACs are counted as for the hardware (manifest): every Conv2d output element costs K*K*Cin/groups MACs, padding
positions included; GDN / IGDN, activations and PixelShuffle are not counted.

    python arch_compare.py [--json out.json]
"""
import argparse
import json

import torch
from torch import nn

import deepjsccq_model as M


def build(c, cout, enc_strides, dec_scales):
    M._ARCH.update(gdn_param='compressai', attn_residual=True, rb_act_before_add=True)    # paper blocks
    try:
        s = enc_strides
        enc = nn.Sequential(
            M.ResidualBlockWithStride(3, c, s[0]), M.ResidualBlock(c, c),
            M.ResidualBlockWithStride(c, c, s[1]), M.AttentionBlock(c),
            M.ResidualBlock(c, c), M.ResidualBlockWithStride(c, c, s[2]),
            M.ResidualBlock(c, c), M.ResidualBlockWithStride(c, cout, s[3]),
            M.AttentionBlock(cout))
        r = dec_scales
        dec = nn.Sequential(
            M.AttentionBlock(cout), M.ResidualBlock(cout, c),
            M.ResidualBlockUpsample(c, c, r[0]), M.ResidualBlock(c, c),
            M.ResidualBlockUpsample(c, c, r[1]), M.AttentionBlock(c),
            M.ResidualBlock(c, c), M.ResidualBlockUpsample(c, c, r[2]),
            M.ResidualBlock(c, c), M.ResidualBlockUpsample(c, 3, r[3]))
    finally:
        M._ARCH.update(gdn_param='softplus', attn_residual=False, rb_act_before_add=False)
    return enc, dec


def count(net, x):
    macs, conv_w = [0], [0]

    def hook(mod, inp, out):
        k = mod.kernel_size[0] * mod.kernel_size[1] * mod.in_channels // mod.groups
        macs[0] += out.numel() * k
    hs = [m.register_forward_hook(hook) for m in net.modules() if isinstance(m, nn.Conv2d)]
    with torch.no_grad():
        y = net(x)
    for h in hs:
        h.remove()
    conv_w[0] = sum(m.weight.numel() for m in net.modules() if isinstance(m, nn.Conv2d))
    params = sum(p.numel() for p in net.parameters())
    return y, macs[0], conv_w[0], params


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--json')
    a = ap.parse_args()
    cfgs = {
        'paper (C=256, 16x down)': (256, 256, [2, 2, 2, 2], [2, 2, 2, 2]),
        'fpga (C=32, 4x down)': (32, 16, [2, 2, 1, 1], [1, 1, 2, 2]),
    }
    res = {}
    for name, (c, cout, s, r) in cfgs.items():
        enc, dec = build(c, cout, s, r)
        z, me, we, pe = count(enc, torch.zeros(1, 3, 256, 256))
        y, md, wd, pd = count(dec, torch.zeros_like(z))
        res[name] = dict(latent=list(z.shape[1:]), latent_elems=z.numel(), out=list(y.shape[1:]),
                         enc_gmac=me / 1e9, dec_gmac=md / 1e9, enc_conv_weights=we, dec_conv_weights=wd,
                         enc_params=pe, dec_params=pd)
        print(f"{name:26s} latent {tuple(z.shape[1:])} = {z.numel()}  enc {me/1e9:.3f} GMAC {pe:,} params  "
              f"dec {md/1e9:.3f} GMAC {pd:,} params  conv weights {we:,} / {wd:,}")
    if a.json:
        json.dump(res, open(a.json, 'w'), indent=1)


if __name__ == '__main__':
    main()
