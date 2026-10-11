"""Received DeepJSCC-Q / SSCC constellations (equalizer output, data subcarriers) at three attenuation points of the
over-the-air sweep in data/measurements/psnr_snr (k0802_v3).

    python const_plot.py      -> ../results/const_ota.png
"""
import json
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
MEAS = os.path.join(ROOT, "data", "measurements", "psnr_snr")
OUT = os.path.join(HERE, "..", "results")
os.makedirs(OUT, exist_ok=True)
plt.rcParams.update({"font.family": ["Times New Roman", "SimSun"], "font.size": 9, "axes.unicode_minus": False})

NULLS = set(range(0, 6)) | {32} | set(range(59, 64))
PILOTS = [11, 25, 39, 53]
DATA = [k for k in range(64) if k not in NULLS and k not in PILOTS]
QAM = np.array([-1106, -790, -474, -158, 158, 474, 790, 1106])

da = json.load(open(os.path.join(MEAS, "k0802_v3_da.json"), encoding="utf-8"))
snr = {(r["mode"], round(float(r["att"]), 2)): r for r in da["results"]}


def load(mode, att):
    d = np.load(os.path.join(MEAS, "constellations", f"{mode}_{att:05.2f}dB_p0.npz"))
    return d["cpe"][:, :, DATA].reshape(-1)


points = [0.0, 20.0, 32.0]
fig, axs = plt.subplots(1, 3, figsize=(6.3, 2.35), dpi=300)
for ax, att in zip(axs, points):
    z = load("jscc", att)
    r = snr.get(("jscc", att), {})
    ax.plot(z.real, z.imag, ".", ms=0.6, alpha=0.25, color="#2b6c8f", rasterized=True)
    for v in QAM:
        ax.axvline(v, color="#d9d9d9", lw=0.3, zorder=0); ax.axhline(v, color="#d9d9d9", lw=0.3, zorder=0)
    ax.set_xlim(-1500, 1500); ax.set_ylim(-1500, 1500); ax.set_aspect("equal")
    ax.set_xticks([]); ax.set_yticks([])
    s = r.get("snr_da_db")
    ax.set_title(f"数据辅助 SNR {s:.1f} dB\n解码 PSNR {r['psnr_shown']:.2f} dB", fontsize=8.5)
fig.tight_layout(); fig.savefig(os.path.join(OUT, "const_ota.png"), bbox_inches="tight", pad_inches=0.03); plt.close(fig)
print({p: snr.get(("jscc", p), {}).get("snr_da_db") for p in points})
