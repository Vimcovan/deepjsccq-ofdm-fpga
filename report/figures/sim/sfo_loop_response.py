"""Step / ramp response of the RX CPE compensation + SFO tracking loop (sfo_rotator, cpe_compensation, sfo_residual),
simulated symbol by symbol with the same arithmetic as the RTL (floating point, no noise):

  per data symbol n, subcarrier k:  phase = c_n + theta_n * k        (c: common phase, theta: slope, rad/subcarrier)
  sfo_rotator      : multiply by exp(-j k P_n), P_n = A + R          (P_n: predicted slope of this symbol)
  cpe_compensation : G = mean of the 4 pilots (k = -21, -7, 7, 21), every subcarrier * 1024 / G
  sfo_residual     : L = -21 Im p(-21) - 7 Im p(-7) + 7 Im p(7) + 21 Im p(21),  e = L * 170 (pi-scaled, 2^29 = pi)
  update (after the symbol, effective from symbol n + 1):  R <- R + e/256,  A <- P_n + e/8
  A = R = 0 at the first data symbol of a frame.

(a) CPE only: common phase step of 60 deg at symbol 50, no slope.
(b) slope step: timing offset step of 0.25 / 0.5 / 1 sample at symbol 50 (slope 2 pi d / 64), no CPE.
(c) ramp (SFO only): 40 ppm, timing drift 40e-6 * 80 samples per OFDM symbol, over one frame (683 symbols);
    actual phase of the edge subcarrier vs the phase removed by sfo_rotator, with a zoom on the start.

    python sfo_loop_response.py      -> ../hw/sfo_loop_response.png
"""
import os

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "hw", "sfo_loop_response.png")
import plotstyle as S
S.apply()

NSYM = 683
KP = np.array([-21, -7, 7, 21])                  # pilot subcarriers
W = np.array([-21, -7, 7, 21])                   # LS weights (pilot polarity already removed)
PI_UNIT = 2 ** 29 / np.pi                        # pi-scaled fixed-point unit per radian
K_EDGE = 26                                      # outermost data subcarrier


def run(c, theta):
    """c, theta: common phase / slope per symbol (rad, rad/subcarrier).
    Returns residual common phase and residual slope after the loop, and the predicted slope P."""
    A = R = 0.0
    res_c, res_s, pred = [], [], []
    for n in range(len(c)):
        P = 0.0 if n == 0 else (A + R) / PI_UNIT
        p = np.exp(1j * (c[n] + (theta[n] - P) * KP))            # pilots after sfo_rotator
        G = p.mean()
        q = p / G * 1024                                         # after cpe_compensation
        L = float(np.sum(W * q.imag))
        e = L * 170                                              # pi-scaled units
        if n == 0:
            R = 0.0
        R, A = R + e / 256, P * PI_UNIT + e / 8
        res_c.append(np.angle(np.exp(1j * (c[n] - np.angle(G)))))  # common phase left at k = 0
        res_s.append(theta[n] - P)
        pred.append(P)
    return np.array(res_c), np.array(res_s), np.array(pred)


def settle(x, target, tol):
    """first symbol after which |x - target| stays within tol * |target|"""
    bad = np.nonzero(np.abs(x - target) > tol * abs(target))[0]
    return bad[-1] + 1 if len(bad) else 0


n = np.arange(NSYM)
N0 = 50
fig, ax = plt.subplots(1, 3, figsize=(7.2, 2.5), dpi=300)

# (a) CPE step
c = np.where(n >= N0, np.deg2rad(60), 0.0)
rc, rs, P = run(c, np.zeros(NSYM))
m = n < 150
ax[0].plot(n[m], np.rad2deg(c[m]), color=S.GRAY, lw=1.0, ls="--", label="输入公共相位")
ax[0].plot(n[m], np.rad2deg(rc[m]), color=S.ORANGE, lw=1.2, label="补偿后残余公共相位")
ax[0].plot(n[m], np.rad2deg(K_EDGE * P[m]), color=S.BLUE, lw=1.0, ls=":", label="斜率环输出（×26）")
ax[0].set_ylim(-10, 70)
ax[0].set_xlabel("OFDM 符号序号")
ax[0].set_ylabel("相位 / °")
ax[0].set_title("(a) CPE 阶跃 60°", fontsize=9)
ax[0].legend(frameon=False, fontsize=7, loc="center right")
print(f"(a) max residual CPE {np.rad2deg(np.abs(rc).max()):.2e} deg, max slope-loop output {np.abs(P).max():.2e}")

# (b) slope step
m = n < 150
for d, col in ((0.25, S.LBLUE), (0.5, S.BLUE), (1.0, S.ORANGE)):
    th0 = 2 * np.pi * d / 64
    theta = np.where(n >= N0, th0, 0.0)
    _, rs, P = run(np.zeros(NSYM), theta)
    y = P / th0
    t5, t2 = settle(y[N0:], 1.0, 0.05), settle(y[N0:], 1.0, 0.02)
    print(f"(b) step {d} sample: overshoot {100 * (y.max() - 1):.1f} %, 5 % settling {t5} sym, 2 % {t2} sym")
    ax[1].plot(n[m], y[m], color=col, lw=1.2, label=f"定时阶跃 {d:g} 采样")
ax[1].axhline(1.0, color=S.GRAY, lw=0.6, ls="--")
ax[1].set_xlabel("OFDM 符号序号")
ax[1].set_ylabel("预测斜率 / 实际斜率")
ax[1].set_title("(b) 相位斜率阶跃", fontsize=9)
ax[1].legend(frameon=False, fontsize=7, loc="center right", bbox_to_anchor=(1.0, 0.45))

# (c) SFO ramp: actual phase ramp at the edge subcarrier vs the phase the loop removes (k * predicted slope)
eps = 40e-6
tau = eps * 80 * (n + 1)                          # timing drift since the LTF reference, samples
theta = 2 * np.pi * tau / 64
_, rs, P = run(np.zeros(NSYM), theta)
true_ph, trk_ph = np.rad2deg(K_EDGE * theta), np.rad2deg(K_EDGE * P)
err = true_ph - trk_ph
ax[2].plot(n, true_ph, color=S.GRAY, lw=1.0, ls="--", label="实际相位斜坡")
ax[2].plot(n, trk_ph, color=S.ORANGE, lw=1.2, label="跟踪环补偿的相位")
ax[2].set_xlabel("OFDM 符号序号")
ax[2].set_ylabel("k = 26 子载波相位 / °")
ax[2].set_title("(c) SFO 斜坡 40 ppm", fontsize=9)
ax[2].legend(frameon=False, fontsize=7, loc="upper left")
ins = ax[2].inset_axes([0.50, 0.08, 0.46, 0.42])
z = n < 40
ins.plot(n[z], true_ph[z], color=S.GRAY, lw=1.0, ls="--")
ins.plot(n[z], trk_ph[z], color=S.ORANGE, lw=1.2)
ins.set_xlim(0, 39); ins.set_ylim(0, true_ph[39] * 1.05)
ins.tick_params(labelsize=6, length=2)
ins.grid(color="#dddddd", lw=0.4); ins.set_axisbelow(True)
ax[2].indicate_inset_zoom(ins, edgecolor="#555555", lw=0.6)
print(f"(c) drift at frame end {tau[-1]:.2f} samples, edge phase {true_ph[-1]:.0f} deg; "
      f"tracking error peak {np.abs(err).max():.2f} deg at symbol {np.abs(err).argmax()}, "
      f"after symbol 100 max {np.abs(err[100:]).max():.3f} deg, at frame end {err[-1]:.4f} deg")

for a in ax:
    a.grid(color="#dddddd", lw=0.4)
    a.set_axisbelow(True)
    for s in ("top", "right"):
        a.spines[s].set_visible(False)
fig.tight_layout()
fig.savefig(OUT, bbox_inches="tight", pad_inches=0.03)
print("written", os.path.normpath(OUT))
