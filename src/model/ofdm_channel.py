"""802.11a-style OFDM link model for DeepJSCC-Q, as a drop-in for model.channel.

Chain (per image = one frame):
  latent I/Q symbols -> scrambler (pseudo-random permutation + j^r rotation,
  which maps 64-QAM onto itself) -> 48 data subcarriers per OFDM symbol, 4 BPSK
  pilots with the 802.11a polarity sequence -> 4x oversampled IFFT -> optional
  amplitude clipping (DAC / PA peak limit) -> in-band FFT -> frequency-selective
  channel H_k (static over the frame) + AWGN -> ZF or MMSE equalization with
  perfect or LTF-estimated CSI -> descrambler -> continuous I/Q to the decoder.

The CP is assumed longer than the channel, so the channel is diagonal per
subcarrier and no time-domain multipath waveform needs to be simulated.
SNR convention matches AWGN in deepjsccq_model: unit average symbol power per
data subcarrier, complex noise variance 10^(-SNR/10) per subcarrier, E|H_k|^2 = 1.
"""
from __future__ import annotations

import math
from typing import Optional

import torch
from torch import Tensor, nn

N_FFT = 64
DATA_SC = [k for k in range(-26, 27) if k not in (0, -21, -7, 7, 21)]
PILOT_SC = [-21, -7, 7, 21]
PILOT_BASE = [1., 1., 1., -1.]


def pilot_polarity() -> Tensor:
    """802.11a pilot polarity p_0..p_126: scrambler x^7+x^4+1, all-ones seed, 0->+1, 1->-1."""
    state = [1] * 7
    out = []
    for _ in range(127):
        bit = state[6] ^ state[3]
        out.append(1. if bit == 0 else -1.)
        state = [bit] + state[:6]
    return torch.tensor(out)


class OFDMChannel(nn.Module):
    def __init__(self, n_symbols: int, snr_db: float = 10.0, *, oversample: int = 4,
                 scramble: bool = True, clip_db: Optional[float] = None,
                 delay_spread: float = 0.0, n_taps: int = 16, equalizer: str = 'mmse',
                 csi: str = 'perfect', est_taps: int = 16, rx_clamp: Optional[float] = None,
                 seed: int = 2026, pdp=None, clip_mode: str = 'circle',
                 mmse_var: Optional[float] = None):
        """pdp: optional [(delay_ns, gain_db), ...] tapped delay line with fractional delays
        at 20 MHz, Rayleigh per path, static over the frame (overrides delay_spread).
        clip_mode: 'circle' = amplitude clip at clip_db above the RMS; 'square' = separate
        I/Q saturation (DAC full scale) at clip_db above the per-component RMS.
        csi: 'perfect' | 'ltf1' (single LTS) | 'ltf' (two LTS averaged) | 'ltf_dft' | 'ltf_ma'.
        equalizer: 'zf' | 'mmse' (true noise var) | 'mmse_est' (var from LTS1 - LTS2) |
        'mmse_fixed' (var = mmse_var).  MMSE is ZF followed by the real per-subcarrier
        weight |H|^2 / (|H|^2 + var), i.e. a post-scaling after an unchanged ZF chain."""
        super().__init__()
        self.snr_db, self.clip_db = float(snr_db), clip_db
        self.oversample, self.delay_spread, self.n_taps = oversample, float(delay_spread), n_taps
        self.equalizer, self.csi, self.rx_clamp = equalizer, csi, rx_clamp
        self.clip_mode, self.mmse_var = clip_mode, mmse_var
        self.register_buffer('pdp_power', None)
        if pdp is not None:
            d = torch.tensor([x[0] for x in pdp], dtype=torch.float64) * 1e-9 * 20e6  # delay in samples
            p = 10 ** (torch.tensor([x[1] for x in pdp], dtype=torch.float64) / 10)
            k = torch.arange(N_FFT, dtype=torch.float64)
            k = torch.where(k < N_FFT // 2, k, k - N_FFT)  # FFT-order bin -> signed frequency
            self.register_buffer('pdp_power', (p / p.sum()).float())
            self.register_buffer('pdp_steer', torch.exp(-2j * math.pi * d[:, None] * k[None, :] / N_FFT)
                                 .to(torch.complex64))
        self.n_symbols = n_symbols
        self.n_ofdm = math.ceil(n_symbols / len(DATA_SC))
        g = torch.Generator().manual_seed(seed)
        perm = torch.randperm(n_symbols, generator=g) if scramble else torch.arange(n_symbols)
        rot = torch.randint(0, 4, (n_symbols,), generator=g) if scramble else torch.zeros(n_symbols, dtype=torch.long)
        self.register_buffer('perm', perm)
        self.register_buffer('inv_perm', torch.argsort(perm))
        self.register_buffer('rot', torch.polar(torch.ones(n_symbols), rot.float() * (math.pi / 2)))
        self.register_buffer('data_idx', torch.tensor([k % N_FFT for k in DATA_SC]))
        self.register_buffer('pilot_idx', torch.tensor([k % N_FFT for k in PILOT_SC]))
        pol = pilot_polarity()[torch.arange(self.n_ofdm) % 127]
        self.register_buffer('pilots', pol[:, None] * torch.tensor(PILOT_BASE))
        # DFT-domain LTF denoising: least-squares fit of an est_taps-long impulse
        # response to the 52 LTF-excited subcarriers, re-evaluated on all 64.
        # A fixed 64x52 complex matrix; the guard/DC nulls rule out plain IFFT truncation.
        obs = torch.tensor(sorted(k % N_FFT for k in DATA_SC + PILOT_SC))
        taps = torch.arange(est_taps)
        f_all = torch.exp(-2j * math.pi * torch.arange(N_FFT)[:, None].double() * taps[None].double() / N_FFT)
        self.register_buffer('ltf_obs', obs)
        self.register_buffer('ltf_proj', (f_all @ torch.linalg.pinv(f_all[obs])).to(torch.complex64))
        # openwifi/openofdm-style smoothing: moving average of the LS estimate over
        # est_taps adjacent used subcarriers, window truncated at the band edges and DC.
        self.register_buffer('ltf_ma', self._moving_average(est_taps))

    @staticmethod
    def _moving_average(length: int) -> Tensor:
        m = torch.zeros(N_FFT, N_FFT, dtype=torch.complex64)
        half = length // 2
        for band in (list(range(-26, 0)), list(range(1, 27))):
            for i, k in enumerate(band):
                nb = band[max(0, i - half):i + half + 1]
                for j in nb:
                    m[k % N_FFT, j % N_FFT] = 1.0 / len(nb)
        return m

    # -- transmitter ---------------------------------------------------------
    def scramble(self, x: Tensor) -> Tensor:
        return x[:, self.perm] * self.rot

    def descramble(self, y: Tensor) -> Tensor:
        return (y * self.rot.conj())[:, self.inv_perm]

    def grid(self, x: Tensor) -> Tensor:
        """(B, n_symbols) complex -> (B, n_ofdm, 64) subcarrier grid, FFT order."""
        b = x.shape[0]
        pad = self.n_ofdm * len(DATA_SC) - x.shape[1]
        data = torch.cat([x, x.new_zeros(b, pad)], 1).view(b, self.n_ofdm, len(DATA_SC))
        g = x.new_zeros(b, self.n_ofdm, N_FFT)
        g[..., self.data_idx] = data
        g[..., self.pilot_idx] = self.pilots.to(x.dtype)
        return g

    def time_signal(self, g: Tensor) -> Tensor:
        """Oversampled time samples (no CP; the CP repeats samples and adds no new peaks)."""
        n_os = N_FFT * self.oversample
        big = g.new_zeros(*g.shape[:-1], n_os)
        # FFT-order bin k (0..63) is frequency k if k < 32 else k - 64.
        freqs = torch.arange(N_FFT, device=g.device)
        freqs = torch.where(freqs < N_FFT // 2, freqs, freqs - N_FFT) % n_os
        big[..., freqs] = g
        return torch.fft.ifft(big, norm='ortho') * math.sqrt(self.oversample)

    def clip(self, g: Tensor) -> Tensor:
        """Amplitude-clip the oversampled signal at clip_db above its mean power; return the in-band grid."""
        if self.clip_db is None:
            return g
        t = self.time_signal(g)
        used = len(DATA_SC) + len(PILOT_SC)
        mean_power = used / N_FFT  # E|t|^2 for unit-power subcarriers, ortho FFT scaled by sqrt(os)
        if self.clip_mode == 'square':
            a = math.sqrt(mean_power / 2) * 10 ** (self.clip_db / 20)
            t = torch.complex(t.real.clamp(-a, a), t.imag.clamp(-a, a))
        else:
            a = math.sqrt(mean_power) * 10 ** (self.clip_db / 20)
            mag = t.abs().clamp_min(1e-12)
            t = t * torch.clamp(a / mag, max=1.0)
        n_os = N_FFT * self.oversample
        big = torch.fft.fft(t / math.sqrt(self.oversample), norm='ortho')
        freqs = torch.arange(N_FFT, device=g.device)
        freqs = torch.where(freqs < N_FFT // 2, freqs, freqs - N_FFT) % n_os
        return big[..., freqs]

    # -- channel ---------------------------------------------------------------
    def channel_response(self, b: int, device) -> Tensor:
        if self.pdp_power is not None:
            gains = torch.randn(b, len(self.pdp_power), dtype=torch.complex64, device=device)
            return (gains * self.pdp_power.sqrt()) @ self.pdp_steer  # E|H_k|^2 = 1
        if self.delay_spread <= 0:
            return torch.ones(b, N_FFT, dtype=torch.complex64, device=device)
        l = torch.arange(self.n_taps, device=device, dtype=torch.float32)
        pdp = torch.exp(-l / self.delay_spread)
        pdp = pdp / pdp.sum()
        taps = torch.randn(b, self.n_taps, dtype=torch.complex64, device=device) * pdp.sqrt()
        return torch.fft.fft(taps, n=N_FFT)  # E|H_k|^2 = sum(pdp) = 1

    def forward(self, iq: Tensor, snr_db: Optional[float] = None) -> Tensor:
        with torch.autocast(device_type=iq.device.type, enabled=False):
            snr = self.snr_db if snr_db is None else float(snr_db)
            x = torch.complex(iq[..., 0].float(), iq[..., 1].float())
            g = self.clip(self.grid(self.scramble(x)))
            h = self.channel_response(x.shape[0], x.device)[:, None, :]
            var = 10 ** (-snr / 10)
            noise = torch.randn_like(g) * math.sqrt(var)  # complex randn has unit total variance
            y = h * g + noise
            # LS estimates from LTS 1 and LTS 2 (known +-1 symbols already removed)
            l1 = h + torch.randn_like(h) * math.sqrt(var)
            l2 = h + torch.randn_like(h) * math.sqrt(var)
            var_est = (l1 - l2)[..., self.ltf_obs].abs().square().mean(-1, keepdim=True) / 2
            if self.csi == 'ltf1':
                h_est = l2
            elif self.csi in ('ltf', 'ltf_dft', 'ltf_ma'):
                h_est = (l1 + l2) / 2
                if self.csi == 'ltf_dft':
                    h_est = (h_est[..., self.ltf_obs] @ self.ltf_proj.T)
                elif self.csi == 'ltf_ma':
                    h_est = h_est @ self.ltf_ma.T
            else:
                h_est = h
            eq = y / h_est
            if self.rx_clamp is not None:  # fixed-point ZF output saturates before the MMSE weight
                eq = torch.complex(eq.real.clamp(-self.rx_clamp, self.rx_clamp),
                                   eq.imag.clamp(-self.rx_clamp, self.rx_clamp))
            if self.equalizer != 'zf':
                v = {'mmse': var, 'mmse_est': var_est, 'mmse_fixed': self.mmse_var}[self.equalizer]
                p = h_est.abs().square()
                eq = eq * (p / (p + v))  # == conj(H) y / (|H|^2 + var)
            data = eq[..., self.data_idx].reshape(x.shape[0], -1)[:, :self.n_symbols]
            out = self.descramble(data)
            out = torch.stack((out.real, out.imag), -1)
            if self.rx_clamp is not None:
                out = out.clamp(-self.rx_clamp, self.rx_clamp)
            return out.to(iq.dtype)

    @torch.no_grad()
    def papr_db(self, iq: Tensor) -> Tensor:
        """Per-OFDM-symbol PAPR (dB) of the oversampled transmit signal, before clipping."""
        x = torch.complex(iq[..., 0].float(), iq[..., 1].float())
        t = self.time_signal(self.grid(self.scramble(x)))
        p = t.abs().square()
        return 10 * torch.log10(p.amax(-1) / p.mean(-1)).flatten()
