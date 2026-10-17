"""Why the RX reorders the FFT output (fft_ifft_shift) before the SFO tracking loop.

A timing offset of d samples rotates subcarrier k by 2 pi k d / 64, a straight line in the physical subcarrier order
(k = -32 ... 31). The FFT IP outputs bins in natural order (DC, positive, then negative frequencies), where the same
phases form two pieces with a jump in the middle; a least-squares line through the 4 pilots then gives a wrong slope.

    python fftshift_phase.py      -> ../hw/fftshift_phase.png
"""
import os

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "hw", "fftshift_phase.png")
import plotstyle as S
S.apply()

D = 1.0                                            # timing offset, samples
k = np.arange(-32, 32)
used = (np.abs(k) <= 26) & (k != 0)                # 48 data + 4 pilot subcarriers
pil = np.isin(k, [-21, -7, 7, 21])
ph = np.rad2deg(2 * np.pi * k * D / 64)

fig, ax = plt.subplots(1, 2, figsize=(7.2, 2.6), dpi=300, sharey=True)
for a, idx, title in ((ax[0], k % 64, "(a) FFT 自然顺序（DC → 正频率 → 负频率）"),
                      (ax[1], k + 32, "(b) fftshift 后（负频率 → DC → 正频率）")):
    a.scatter(idx[used & ~pil], ph[used & ~pil], s=6, color=S.BLUE, label="数据子载波", zorder=3)
    a.scatter(idx[pil], ph[pil], s=22, marker="D", color=S.ORANGE, label="导频", zorder=4)
    c = np.polyfit(idx[pil], ph[pil], 1)           # LS line through the pilots, as the slope estimator does
    x = np.array([0, 63])
    a.plot(x, np.polyval(c, x), color=S.GRAY, lw=1.0, ls="--", label="导频直线拟合")
    a.axhline(0, color="#999999", lw=0.5)
    a.set_xlim(-2, 65)
    a.set_xticks([0, 16, 32, 48, 63])
    a.set_xlabel("FFT 输出序号")
    a.set_title(title, fontsize=9)
    S.finish(a)
    print(f"{title}: fitted slope {c[0]:.2f} deg/bin (true {360 * D / 64:.2f})")
ax[0].set_ylabel("子载波相位 / °")
ax[0].legend(fontsize=7, loc="lower left")
fig.tight_layout()
fig.savefig(OUT, bbox_inches="tight", pad_inches=0.03)
print("written", os.path.normpath(OUT))
