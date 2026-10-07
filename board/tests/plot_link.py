"""Figures from measure_link.py results: PSNR / SSCC frame success / EVM vs extra TX attenuation.

    python plot_link.py meas_link.json [out_prefix]
-> <out>_psnr.png, <out>_sscc.png, <out>_evm.png, <out>_table.md (mean over passes, min..max)
A point measured with no decodable image (PSNR null) is PSNR = -inf: "−∞" in the table, ▼ at the axis bottom.
"""
import json
import sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

src = sys.argv[1]
out = sys.argv[2] if len(sys.argv) > 2 else src.rsplit(".", 1)[0]
R = json.load(open(src))["results"]
SURF, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
COL = {"jscc": "#2a78d6", "sscc": "#eb6834"}                 # reference palette slots 1 / 2 (validated pair)
NAME = {"jscc": "DeepJSCC-Q", "sscc": "SSCC (JPEG + CC + 64QAM)"}
plt.rcParams.update({"font.family": ["Microsoft YaHei", "DejaVu Sans"], "axes.unicode_minus": False, "font.size": 11,
                     "axes.edgecolor": GRID, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
                     "axes.titlecolor": INK, "figure.facecolor": SURF, "axes.facecolor": SURF})


def series(mode, key):
    atts = sorted({r["att"] for r in R if r["mode"] == mode})
    m, lo, hi = [], [], []
    for a in atts:
        v = [r[key] for r in R if r["mode"] == mode and r["att"] == a and r[key] is not None]
        m.append(np.mean(v) if v else np.nan); lo.append(min(v) if v else np.nan); hi.append(max(v) if v else np.nan)
    return np.array(atts), np.array(m), np.array(lo), np.array(hi)


def axes(title, ylabel):
    fig, ax = plt.subplots(figsize=(7.2, 4.2), dpi=150)
    ax.set_title(title, loc="left", fontsize=13, pad=10)
    ax.set_xlabel("额外 TX 衰减 (dB)"); ax.set_ylabel(ylabel)
    ax.grid(True, color=GRID, linewidth=0.8); ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    return fig, ax


def line(ax, mode, key, label=None, dashed=False):
    x, m, lo, hi = series(mode, key)
    ax.fill_between(x, lo, hi, color=COL[mode], alpha=0.15, linewidth=0)
    ax.plot(x, m, color=COL[mode], linewidth=2, linestyle="--" if dashed else "-", marker="o", markersize=5,
            markeredgecolor=SURF, markeredgewidth=1.5, label=label or NAME[mode])
    if key.startswith("psnr"):                                   # measured, nothing decoded: PSNR = -inf (arrow at the
        ninf = [a for a in x if not [r for r in R if r["mode"] == mode and r["att"] == a and r[key] is not None]]
        if ninf:                                                 # bottom of the axis)
            y0 = ax.get_ylim()[0]
            ax.plot(ninf, [y0] * len(ninf), linestyle="none", marker="v", markersize=8, color=COL[mode], clip_on=False)
    k = np.where(~np.isnan(m))[0]
    if len(k):                                                   # direct label at the last valid point
        ax.annotate(label or NAME[mode], (x[k[-1]], m[k[-1]]), xytext=(6, 0), textcoords="offset points",
                    va="center", fontsize=10, color=INK2)
    return x, m


# 1. PSNR as seen by the viewer (an SSCC frame the decoder rejects leaves the last picture on screen)
fig, ax = axes("PSNR 与 TX 衰减（同一信号源、同一发射功率）", "PSNR (dB)")
for mode in ("jscc", "sscc"):
    line(ax, mode, "psnr_shown")
ax.legend(loc="lower left", frameon=False); ax.set_xlim(right=ax.get_xlim()[1] + 4)
fig.tight_layout(); fig.savefig(out + "_psnr.png", facecolor=SURF)

# 2. SSCC frame success
fig, ax = axes("SSCC 帧成功率", "帧比例")
x, m, lo, hi = series("sscc", "crc_ok")
ax.fill_between(x, lo, hi, color=COL["sscc"], alpha=0.15, linewidth=0)
ax.plot(x, m, color=COL["sscc"], linewidth=2, marker="o", markersize=5, markeredgecolor=SURF, label="CRC 正确")
x, m2, lo2, hi2 = series("sscc", "decoded")
ax.plot(x, m2, color=COL["sscc"], linewidth=2, linestyle="--", marker="s", markersize=5, markeredgecolor=SURF,
        label="JPEG 可解码")
ax.set_ylim(-0.03, 1.05); ax.legend(loc="lower left", frameon=False)
fig.tight_layout(); fig.savefig(out + "_sscc.png", facecolor=SURF)

# 3. EVM (both modes run the same PHY: the curves should coincide)
fig, ax = axes("最终星座 EVM", "EVM (dB)")
for mode in ("jscc", "sscc"):
    line(ax, mode, "evm_db")
ax.legend(loc="upper left", frameon=False); ax.set_xlim(right=ax.get_xlim()[1] + 4)
fig.tight_layout(); fig.savefig(out + "_evm.png", facecolor=SURF)

# 4. PSNR vs constellation SNR (= -EVM of the final constellation, what the decoders get): every measured window
# (style of the usual DeepJSCC papers: boxed axes, grid, the y range on the DeepJSCC degradation; the SSCC cliff
# leaves the plot at the bottom - below it nearly every frame fails and its PSNR means nothing)
from matplotlib.ticker import MultipleLocator
SRCS = sorted({r.get("src", "video") for r in R})
DA = any(r.get("snr_da_db") is not None for r in R)            # analyze_const.py: data-aided SNR available
xsnr = (lambda r: r.get("snr_da_db")) if DA else (lambda r: None if r["evm_db"] is None else -r["evm_db"])
with plt.rc_context({"axes.edgecolor": INK, "axes.labelcolor": INK, "xtick.color": INK, "ytick.color": INK,
                     "figure.facecolor": "white", "axes.facecolor": "white", "font.size": 12}):
    fig, ax = plt.subplots(figsize=(6.4, 4.8), dpi=150)
    ax.set_title("OTA 实测 · " + ", ".join(s.replace("preset:div2k_", "DIV2K ") for s in SRCS), fontsize=13,
                 fontweight="bold")
    ax.set_xlabel("SNR（星座点，dB）" if DA else "SNR = −EVM (dB)"); ax.set_ylabel("PSNR (dB)")
    ax.grid(True, color="#d9d9d9", linewidth=0.8); ax.set_axisbelow(True)
    MK = {"jscc": dict(marker="o", markersize=5.5), "sscc": dict(marker=">", markersize=6)}
    for mode in ("jscc", "sscc"):
        pts = sorted((xsnr(r), r["psnr_shown"]) for r in R if r["mode"] == mode and xsnr(r) is not None
                     and r["psnr_shown"] is not None)
        ax.plot([p[0] for p in pts], [p[1] for p in pts], color=COL[mode], linewidth=1.6, markerfacecolor="white",
                markeredgewidth=1.3, label=NAME[mode], **MK[mode])
    ax.set_ylim(19, 33.5); ax.yaxis.set_major_locator(MultipleLocator(2))
    xs = [xsnr(r) for r in R if xsnr(r) is not None]
    ax.set_xlim(np.floor(min(xs)) - 0.5, np.ceil(max(xs)) + 0.5); ax.xaxis.set_major_locator(MultipleLocator(3))
    ax.legend(loc="lower right", frameon=True, edgecolor=INK, fancybox=False, fontsize=10.5)
    fig.tight_layout(); fig.savefig(out + "_psnr_evm.png", facecolor="white")

# table
keys =[("psnr_shown", "PSNR 观看 (dB)"), ("psnr_decoded", "PSNR 已解码 (dB)"), ("crc_ok", "CRC 正确"),
        ("decoded", "可解码"), ("evm_db", "EVM (dB)"), ("sync_per_s", "同步帧/s"), ("agc_gain", "AGC 增益")]
if DA:
    keys.insert(4, ("snr_da_db", "星座 SNR (dB)")); keys.insert(5, ("snr_da_excl", "剔除快照"))
lines = []
for mode in ("jscc", "sscc"):
    lines += [f"\n### {NAME[mode]}\n", "| 衰减 (dB) | " + " | ".join(k[1] for k in keys) + " |",
              "|---" * (len(keys) + 1) + "|"]
    atts = sorted({r["att"] for r in R if r["mode"] == mode})
    for a in atts:
        cells = []
        for k, _ in keys:
            v = [r[k] for r in R if r["mode"] == mode and r["att"] == a and r[k] is not None]
            cells.append(("−∞" if k.startswith("psnr") else "–") if not v else
                         (f"{np.mean(v):.2f}" if len(v) == 1 or max(v) - min(v) < 0.005 else
                                            f"{np.mean(v):.2f} ({min(v):.2f}–{max(v):.2f})"))
        lines.append(f"| +{a:g} | " + " | ".join(cells) + " |")
open(out + "_table.md", "w", encoding="utf-8").write(
    f"# 链路实测（{src}）\n\n各点为 {max(r['pass'] for r in R) + 1} 遍测量的均值（括号内为最小–最大）。\n" + "\n".join(lines) + "\n")
print("written", out + "_{psnr,sscc,evm,psnr_evm}.png", out + "_table.md")
