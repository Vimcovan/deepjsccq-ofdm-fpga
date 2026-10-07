"""Float32 DeepJSCC-Q model for the 2022 JSAIT baseline and FPGA variant.

The receiver consumes continuous equalized I/Q samples.  The only hard
operation in the training path is the straight-through 64-QAM transmitter.
"""
from __future__ import annotations

import math
from typing import Optional, Tuple

import torch
from torch import Tensor, nn
import torch.nn.functional as F

LEAKY_SLOPE = 1.0 / 128.0

# Architecture switches.  Defaults reproduce the checkpoints trained before
# 2026-09-28; ``paper=True`` in DeepJSCCQ selects the JSAIT Fig. 3 / Cheng 2020
# (CompressAI) block definitions.  Set by DeepJSCCQ before building modules.
_ARCH = {'gdn_param': 'softplus', 'attn_residual': False, 'rb_act_before_add': False}


class _LowerBound(torch.autograd.Function):
    """CompressAI lower bound: gradient passes when x >= bound or it pushes x up."""
    @staticmethod
    def forward(ctx, x, bound):
        ctx.save_for_backward(x, bound)
        return torch.max(x, bound)

    @staticmethod
    def backward(ctx, grad):
        x, bound = ctx.saved_tensors
        return ((x >= bound) | (grad < 0)).to(grad.dtype) * grad, None


class NonNegative(nn.Module):
    """CompressAI NonNegativeParametrizer: value = max(p, bound)^2 - pedestal."""
    def __init__(self, minimum: float = 0.0, offset: float = 2 ** -18):
        super().__init__()
        self.pedestal = offset ** 2
        self.register_buffer('bound', torch.tensor((minimum + self.pedestal) ** 0.5))

    def init(self, x: Tensor) -> Tensor:
        return torch.sqrt(torch.clamp(x + self.pedestal, min=self.pedestal))

    def forward(self, p: Tensor) -> Tensor:
        return _LowerBound.apply(p, self.bound.to(p.dtype)) ** 2 - self.pedestal


class GDN(nn.Module):
    def __init__(self, channels: int, inverse: bool = False):
        super().__init__()
        self.inverse = inverse
        self.param = _ARCH['gdn_param']
        if self.param == 'compressai':
            self.beta_reparam, self.gamma_reparam = NonNegative(1e-6), NonNegative()
            self.beta = nn.Parameter(self.beta_reparam.init(torch.ones(channels)))
            self.gamma = nn.Parameter(self.gamma_reparam.init(torch.eye(channels) * 0.1))
        else:
            self.beta = nn.Parameter(torch.ones(channels))
            self.gamma = nn.Parameter(torch.eye(channels) * 0.1)

    def effective(self) -> Tuple[Tensor, Tensor]:
        if self.param == 'compressai':
            return self.beta_reparam(self.beta), self.gamma_reparam(self.gamma)
        return F.softplus(self.beta) + 1e-6, F.softplus(self.gamma)

    def forward(self, x: Tensor) -> Tensor:
        beta, gamma = self.effective()
        gamma = gamma.view(x.shape[1], x.shape[1], 1, 1)
        norm = F.conv2d(x.square(), gamma, beta)
        norm = torch.sqrt(norm + 1e-6) if self.inverse else torch.rsqrt(norm + 1e-6)
        return x * norm


def conv3x3(cin: int, cout: int, stride: int = 1) -> nn.Conv2d:
    return nn.Conv2d(cin, cout, 3, stride=stride, padding=1)


class ResidualBlockWithStride(nn.Module):
    def __init__(self, cin: int, cout: int, stride: int = 2):
        super().__init__()
        self.conv1, self.conv2 = conv3x3(cin, cout, stride), conv3x3(cout, cout)
        self.gdn = GDN(cout)
        self.skip = nn.Conv2d(cin, cout, 1, stride=stride) if (cin != cout or stride != 1) else nn.Identity()
        self.act = nn.LeakyReLU(LEAKY_SLOPE, inplace=True)

    def forward(self, x):
        y = self.gdn(self.conv2(self.act(self.conv1(x))))
        return y + self.skip(x)


class ResidualBlock(nn.Module):
    def __init__(self, cin: int, cout: int):
        super().__init__()
        self.conv1, self.conv2 = conv3x3(cin, cout), conv3x3(cout, cout)
        self.skip = nn.Conv2d(cin, cout, 1) if cin != cout else nn.Identity()
        self.act = nn.LeakyReLU(LEAKY_SLOPE, inplace=True)
        self.act_before_add = _ARCH['rb_act_before_add']

    def forward(self, x):
        if self.act_before_add:  # paper Fig. 3 / CompressAI
            return self.act(self.conv2(self.act(self.conv1(x)))) + self.skip(x)
        return self.act(self.conv2(self.act(self.conv1(x))) + self.skip(x))


class ResidualBlockUpsample(nn.Module):
    def __init__(self, cin: int, cout: int, scale: int = 2):
        super().__init__()
        self.scale = scale
        self.conv = nn.Conv2d(cin, cout * scale * scale, 3, padding=1)
        self.conv2 = conv3x3(cout, cout)
        self.igdn = GDN(cout, inverse=True)
        self.skip = nn.Conv2d(cin, cout * scale * scale, 3, padding=1)
        self.act = nn.LeakyReLU(LEAKY_SLOPE, inplace=True)

    def forward(self, x):
        y = F.pixel_shuffle(self.conv(x), self.scale)
        y = self.igdn(self.conv2(self.act(y)))
        s = F.pixel_shuffle(self.skip(x), self.scale)
        return y + s


class ResidualUnit(nn.Module):
    """Cheng 2020 / CompressAI attention unit: relu(conv(x) + x)."""
    def __init__(self, body: nn.Module):
        super().__init__()
        self.body = body
        self.relu = nn.ReLU(inplace=True)

    def forward(self, x):
        return self.relu(self.body(x) + x)


class AttentionBlock(nn.Module):
    def __init__(self, channels: int):
        super().__init__()
        hidden = max(channels // 2, 1)
        residual = _ARCH['attn_residual']

        def unit():
            body = nn.Sequential(nn.Conv2d(channels, hidden, 1), nn.ReLU(inplace=True),
                                 conv3x3(hidden, hidden), nn.ReLU(inplace=True),
                                 nn.Conv2d(hidden, channels, 1))
            return ResidualUnit(body) if residual else body

        self.a = nn.Sequential(unit(), unit(), unit())
        self.b = nn.Sequential(unit(), unit(), unit(), nn.Conv2d(channels, channels, 1))

    def forward(self, x):
        return x + self.a(x) * torch.sigmoid(self.b(x))


class Encoder(nn.Module):
    def __init__(self, c: int = 32, cout: int = 16):
        super().__init__()
        self.net = nn.Sequential(
            ResidualBlockWithStride(3, c, 2), ResidualBlock(c, c),
            ResidualBlockWithStride(c, c, 2), AttentionBlock(c),
            ResidualBlock(c, c), ResidualBlockWithStride(c, c, 1),
            ResidualBlock(c, c), ResidualBlockWithStride(c, cout, 1),
            AttentionBlock(cout),
        )

    def forward(self, x): return self.net(x)


class Decoder(nn.Module):
    def __init__(self, c: int = 32, cout: int = 16):
        super().__init__()
        self.net = nn.Sequential(
            AttentionBlock(cout), ResidualBlock(cout, c),
            ResidualBlockUpsample(c, c, 1), ResidualBlock(c, c),
            ResidualBlockUpsample(c, c, 1), AttentionBlock(c),
            ResidualBlock(c, c), ResidualBlockUpsample(c, c, 2),
            ResidualBlock(c, c), ResidualBlockUpsample(c, 3, 2),
        )

    def forward(self, x): return torch.sigmoid(self.net(x))


def latent_to_iq(z: Tensor) -> Tensor:
    """(B, C, H, W) latent -> (B, H*W*C/2, 2) I/Q symbols in hardware stream order:
    NHWC element order, symbol = channels (2j, 2j+1) of one pixel = (I, Q)."""
    return z.permute(0, 2, 3, 1).reshape(z.shape[0], -1, 2)


def iq_to_latent(iq: Tensor, c: int, h: int, w: int) -> Tensor:
    """Inverse of latent_to_iq: (B, N, 2) -> (B, C, H, W)."""
    return iq.reshape(iq.shape[0], h, w, c).permute(0, 3, 1, 2)


class QAM64STE(nn.Module):
    """Paper soft-to-hard quantizer for a fixed unit-power 64-QAM alphabet.

    The paper quantizes the encoder's complex latent directly: hard forward
    assignment is nearest-constellation, while the backward derivative comes
    from the softmax-weighted constellation (Eq. 12-13).  There is deliberately
    no per-image RMS normalization here; that normalization belongs to the
    non-quantized DeepJSCC comparison (Eq. 23), not DeepJSCC-Q.
    """
    levels = (-7., -5., -3., -1., 1., 3., 5., 7.)

    def __init__(self, sigma_q: float = 5.0):
        super().__init__()
        lev = torch.tensor(self.levels, dtype=torch.float32) / math.sqrt(42.0)
        grid_i, grid_q = torch.meshgrid(lev, lev, indexing='ij')
        self.register_buffer('constellation', torch.stack((grid_i.reshape(-1), grid_q.reshape(-1)), dim=-1))
        self.sigma_q = float(sigma_q)
        self.update_step = 0

    def set_update_step(self, step: int) -> None:
        # Eq. (22): sigma_q(0)=5, +5 every 10000 parameter updates, capped at 100.
        self.update_step = int(step)
        self.sigma_q = min(100.0, 5.0 + 5.0 * (self.update_step // 10000))

    def forward(self, z: Tensor) -> Tensor:
        """Returns the hard symbols; in training mode also stores the batch
        estimate of P(c_j) from the soft weights (Eq. 18) in ``self.probs``.

        For a square QAM the squared distance is d_I^2 + d_Q^2, so the 64-way
        softmax of Eq. (12) factorizes exactly into independent 8-way softmaxes
        over the I and Q levels, and nearest-point search is per-axis rounding.
        This is identical to the 2-D form (see forward_2d) but ~8x cheaper.
        """
        # fp32 throughout: under AMP the einsum below would otherwise run in fp16
        # and its sum over B*N symbols overflows 65504.
        with torch.autocast(device_type=z.device.type, enabled=False):
            return self._forward_separable(z)

    def _forward_separable(self, z: Tensor) -> Tensor:
        # Two real latent entries form one complex I/Q symbol (pairing: latent_to_iq);
        # the per-axis decision itself does not depend on the pairing.
        if z[0].numel() % 2:
            raise ValueError('latent element count must be even for complex I/Q pairing')
        lev = self.constellation[::8, 0]  # the 8 per-axis levels
        d = (z.float().unsqueeze(-1) - lev).square()  # (B, C, H, W, 8)
        hard = lev[d.argmin(dim=-1)]
        w = torch.softmax(-self.sigma_q * d, dim=-1)
        soft = w @ lev
        if self.training:
            w = w.permute(0, 2, 3, 1, 4).reshape(w.shape[0], -1, 2, lev.numel())
            joint = torch.einsum('bni,bnq->iq', w[:, :, 0], w[:, :, 1]) / (w.shape[0] * w.shape[1])
            self.probs = joint.reshape(-1)  # index i*8+q matches self.constellation
        else:
            self.probs = None
        return (hard + soft - soft.detach()).to(z.dtype).view_as(z)

    def forward_2d(self, z: Tensor) -> Tensor:
        """Reference 64-way implementation of Eq. (12)-(13), kept for testing."""
        pairs = latent_to_iq(z).float()
        c = self.constellation
        distances = (pairs.unsqueeze(-2) - c).square().sum(dim=-1)
        hard = c[distances.argmin(dim=-1)]
        weights = torch.softmax(-self.sigma_q * distances, dim=-1)
        self.probs = weights.mean(dim=(0, 1)) if self.training else None
        soft = weights @ c
        return iq_to_latent((hard + soft - soft.detach()).to(z.dtype), *z.shape[1:])


class AWGN(nn.Module):
    def __init__(self, snr_db: float = 10.0):
        super().__init__(); self.snr_db = float(snr_db)

    def forward(self, iq: Tensor, snr_db: Optional[float] = None) -> Tensor:
        snr = self.snr_db if snr_db is None else float(snr_db)
        sigma = math.sqrt(10 ** (-snr / 10) / 2)
        return iq + torch.randn_like(iq) * sigma


class DeepJSCCQ(nn.Module):
    def __init__(self, c: int = 32, cout: int = 16, snr_db: float = 10.0, quantize: bool = True,
                 paper: bool = False):
        super().__init__()
        self.c, self.cout, self.paper = c, cout, paper
        _ARCH.update(gdn_param='compressai' if paper else 'softplus',
                     attn_residual=paper, rb_act_before_add=paper)
        try:
            self.encoder, self.decoder = Encoder(c, cout), Decoder(c, cout)
        finally:
            _ARCH.update(gdn_param='softplus', attn_residual=False, rb_act_before_add=False)
        self.quantizer, self.channel = QAM64STE(), AWGN(snr_db)
        self.quantize = quantize

    def forward(self, image: Tensor, snr_db: Optional[float] = None, return_latent: bool = False):
        z = self.encoder(image)
        z_tx = self.quantizer(z) if self.quantize else z
        # Continuous I/Q is the decoder input after channel/equalization.
        iq = latent_to_iq(z_tx)
        rx = self.channel(iq, snr_db)
        out = self.decoder(iq_to_latent(rx, *z.shape[1:]))
        if return_latent:
            return out, z, z_tx, rx
        return out


def count_parameters(model: nn.Module) -> int:
    return sum(p.numel() for p in model.parameters() if p.requires_grad)
