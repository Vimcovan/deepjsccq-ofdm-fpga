"""Training curves of the deployed DeepJSCC-Q model from data/model/checkpoint/training.csv (one row per epoch).

    python train_curve.py      -> ../results/train_curve.png
"""
import csv
import json
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
CK = os.path.normpath(os.path.join(HERE, "..", "..", "..", "data", "model", "checkpoint"))
OUT = os.path.join(HERE, "..", "results")
plt.rcParams.update({"font.family": ["Times New Roman", "SimSun"], "font.size": 9, "axes.unicode_minus": False})
ACC, ACC2, INK, GRID = "#2b6c8f", "#c0504d", "#222222", "#d9d9d9"

rows = list(csv.DictReader(open(os.path.join(CK, "training.csv"))))
ep = np.array([int(r["epoch"]) for r in rows])
tr = np.array([float(r["train_mse"]) for r in rows])
va = np.array([float(r["val_mse"]) for r in rows])
ps = np.array([float(r["val_psnr"]) for r in rows])
lr = np.array([float(r["lr"]) for r in rows])
best = json.load(open(os.path.join(CK, "summary.json")))

fig, (a1, a2) = plt.subplots(1, 2, figsize=(6.3, 2.5), dpi=300)
a1.semilogy(ep, tr, color=ACC, lw=0.8, label="训练集 MSE")
a1.semilogy(ep, va, color=ACC2, lw=0.8, label="验证集 MSE")
a1.set_xlabel("训练轮数"); a1.set_ylabel("MSE"); a1.set_xlim(0, 1200)
a1.grid(color=GRID, lw=0.4, which="both"); a1.legend(frameon=False, fontsize=8)

a2.plot(ep, ps, color=ACC, lw=0.8, label="验证集 PSNR")
b = best["best_epoch"]
a2.plot([b], [best["val_psnr"]], "o", ms=3.5, color=ACC2)
a2.annotate(f"第 {b} 轮：{best['val_psnr']:.2f} dB（部署）", xy=(b, best["val_psnr"]), xytext=(120, 23.0), fontsize=8,
            arrowprops=dict(arrowstyle="->", lw=0.6, color=INK))
a2.set_xlabel("训练轮数"); a2.set_ylabel("PSNR / dB"); a2.set_xlim(0, 1200); a2.set_ylim(19, 32.5)
a2.grid(color=GRID, lw=0.4)
ax3 = a2.twinx()
ax3.semilogy(ep, lr, color="#7f7f7f", lw=0.7, ls="--", label="学习率")
ax3.set_ylabel("学习率", color="#7f7f7f"); ax3.tick_params(axis="y", colors="#7f7f7f", labelsize=7)
h1, l1 = a2.get_legend_handles_labels(); h2, l2 = ax3.get_legend_handles_labels()
a2.legend(h1 + h2, l1 + l2, frameon=False, fontsize=8, loc="lower right")
fig.tight_layout(); fig.savefig(os.path.join(OUT, "train_curve.png"), bbox_inches="tight", pad_inches=0.03)
print("epochs", len(ep), "final val psnr", ps[-1], "best", best["best_epoch"], best["val_psnr"], "lr", lr[0], lr[-1])
