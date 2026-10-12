"""Report versions (Chinese labels, report style) of the measurement figures; the data are those of
data/measurements, the MATLAB originals (board/tests/plot_*.m) stay next to the data.

    python meas_plots.py   -> ../results/psnr_snr.png, fps_10min.png, latency_cdf.png
"""
import json
import os

import numpy as np
import matplotlib.pyplot as plt
from scipy.stats import gaussian_kde

import plotstyle as S

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
MEAS = os.path.join(ROOT, "data", "measurements")
OUT = os.path.join(HERE, "..", "results")
S.apply()

# ---------------------------------------------------------------- PSNR vs data-aided SNR
da = json.load(open(os.path.join(MEAS, "psnr_snr", "k0802_v3_da.json"), encoding="utf-8"))
fig, ax = plt.subplots(figsize=(4.2, 3.0))
for mode, name, col, mk in (("jscc", "DeepJSCC-Q", S.BLUE, "o"), ("sscc", "SSCC\n（JPEG + 卷积码 + 64QAM）", S.ORANGE, ">")):
    pts = sorted((r["snr_da_db"], r["psnr_shown"]) for r in da["results"]
                 if r["mode"] == mode and r.get("snr_da_db") is not None and r.get("psnr_shown") is not None)
    x, y = np.array(pts).T
    ax.plot(x, y, "-" + mk, color=col, lw=1.1, ms=3.6, mfc="white", mew=0.9, label=name)
ax.set_ylim(19, 33.5); ax.set_yticks(range(19, 34, 2))
ax.set_xlim(4.5, 33.5); ax.set_xticks(range(6, 34, 3))
ax.set_xlabel("数据辅助 SNR / dB"); ax.set_ylabel("PSNR / dB")
ax.legend(loc="lower right", fontsize=7.5, handlelength=1.6)
S.finish(ax)
S.save(fig, os.path.join(OUT, "psnr_snr.png"))

# ---------------------------------------------------------------- frame rate over 10 minutes + PDF
d = np.genfromtxt(os.path.join(MEAS, "fps", "lat_video_10min_jscc2_jscc_0dB.csv"), delimiter=",", names=True)
t, f = d["t_min"], d["fps"]
ok = ~np.isnan(f); t, f = t[ok], f[ok]
fig, (a1, a2) = plt.subplots(1, 2, figsize=(6.3, 2.0), gridspec_kw=dict(width_ratios=[5, 1], wspace=0.06), sharey=True)
a1.plot(t, f, color=S.BLUE, lw=0.25)
a1.axhline(30, color=S.ORANGE, lw=0.8, ls="--")
a1.set_xlim(0, np.ceil(t.max())); a1.set_ylim(20, 70)
a1.set_xlabel("时间 / min"); a1.set_ylabel("帧率 / fps")
yy = np.linspace(20, 70, 600)
pdf = gaussian_kde(f)(yy)
a2.plot(pdf, yy, color=S.BLUE, lw=1.1)
a2.axhline(30, color=S.ORANGE, lw=0.8, ls="--")
a2.set_xlim(0, 1.1 * pdf.max()); a2.set_xticks([0.1, 0.2]); a2.set_xlabel("概率密度")
S.finish(a1); S.finish(a2)
a2.tick_params(axis="y", left=False)
print(f"fps: mean {f.mean():.2f}, median {np.median(f):.2f}, n {f.size}")
S.save(fig, os.path.join(OUT, "fps_10min.png"))

# ---------------------------------------------------------------- latency CDF of the three PL segments
names = [("encoding", "(a) 编码"), ("decoding", "(b) 解码"), ("transmission", "(c) 传输")]
fig, axs = plt.subplots(1, 3, figsize=(6.3, 2.0))
for ax, (key, title) in zip(axs, names):
    x = np.sort(np.loadtxt(os.path.join(MEAS, "latency", f"segments_3seg_{key}.csv"), ndmin=1))
    lo, hi = np.percentile(x, [0.5, 99.5]); pad = 0.12 * (hi - lo)
    for v in (lo, hi):
        ax.axvline(v, color=S.GRAY, lw=0.7, ls="--")
    ax.step(x, np.arange(1, x.size + 1) / x.size, where="post", color=S.BLUE, lw=1.1)
    ax.axvline(np.median(x), color=S.ORANGE, lw=0.7, ls=":")
    ax.set_xlim(lo - pad, hi + pad); ax.set_ylim(0, 1.02); ax.set_yticks([0, 0.5, 1])
    ax.set_xlabel(f"时延 / ms\n{title}，中位数 {np.median(x):.2f} ms")
    ax.set_ylabel("CDF" if ax is axs[0] else "")
    S.finish(ax)
    print(f"{key}: median {np.median(x):.3f}, p0.5 {lo:.3f}, p99.5 {hi:.3f}, n {x.size}")
fig.tight_layout()
S.save(fig, os.path.join(OUT, "latency_cdf.png"))
