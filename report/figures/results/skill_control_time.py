"""Skill control experiment: task time with / without the skill, Grok 4.7 (Cursor CLI) and DeepSeek V4.1 Flash
(CodeBuddy CLI), same prompts, fresh workspaces.  Output: skill_control_time.png next to this script."""
import os

import matplotlib.pyplot as plt
import numpy as np

OUT = os.path.dirname(os.path.abspath(__file__))
plt.rcParams.update({"font.family": ["Times New Roman", "SimSun"], "font.size": 9, "axes.unicode_minus": False})

scenes = ["DMA遗留传输", "Mali-400", "板载屏排版", "开机自启", "补编内核模块"]
t = {                                     # seconds
    "Grok 无技能":     [1199, 1321, 514, 1404, 1783],
    "Grok 有技能":     [479, 132, 295, 295, 392],
    "DeepSeek 无技能": [143, 401, 218, 202, 2530],
    "DeepSeek 有技能": [24, 96, 81, 137, 160],
}
colors = ["#b9c7d8", "#2f5d8a", "#f2c6a0", "#c8602a"]
hatch = ["", "", "", ""]

fig, ax = plt.subplots(figsize=(6.3, 2.8), dpi=300)
x = np.arange(len(scenes))
w = 0.2
for i, (name, v) in enumerate(t.items()):
    xs = x + (i - 1.5) * w
    ax.bar(xs, v, w, label=name, color=colors[i], edgecolor="#333333", linewidth=0.4, hatch=hatch[i])
    for xx, vv in zip(xs, v):
        ax.text(xx, vv + 30, str(vv), ha="center", va="bottom", fontsize=6.5, rotation=90)
ax.set_ylim(0, 2850)
ax.set_ylabel("完成时间 / s")
ax.set_xticks(x)
ax.set_xticklabels(scenes)
ax.grid(axis="y", color="#dddddd", lw=0.4)
ax.set_axisbelow(True)
for s in ("top", "right"):
    ax.spines[s].set_visible(False)
ax.legend(ncol=4, frameon=False, fontsize=8, loc="upper center", bbox_to_anchor=(0.5, 1.13))
fig.tight_layout()
fig.savefig(os.path.join(OUT, "skill_control_time.png"), bbox_inches="tight", pad_inches=0.03)
print("written", os.path.join(OUT, "skill_control_time.png"))
