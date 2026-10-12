"""Shared matplotlib style of the report's data figures (matches the Visio figures: SimSun + Times New Roman,
dark blue / dark orange accents, light grey grid, open top / right spines).

    import plotstyle as S; S.apply(); ... S.finish(ax); S.save(fig, path)
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BLUE = "#2f5d8a"        # main series
ORANGE = "#c8602a"      # second series, thresholds, highlighted points
GRAY = "#7f7f7f"        # reference / secondary curves, annotations
LBLUE = "#b9c7d8"       # light variants for grouped bars
LORANGE = "#f2c6a0"
INK = "#222222"
GRID = "#dddddd"
SHADE_Y = "#fff2cc"     # background spans (same fills as the Visio figures)
SHADE_B = "#dbeef3"


def apply():
    plt.rcParams.update({
        "font.family": ["Times New Roman", "SimSun"], "font.size": 9, "axes.unicode_minus": False,
        "mathtext.fontset": "stix",
        "axes.linewidth": 0.6, "axes.edgecolor": "#333333", "axes.labelcolor": INK,
        "xtick.major.width": 0.6, "ytick.major.width": 0.6, "xtick.color": INK, "ytick.color": INK,
        "lines.linewidth": 1.1, "grid.color": GRID, "grid.linewidth": 0.4,
        "legend.frameon": False, "legend.fontsize": 8,
        "savefig.dpi": 300,
    })


def finish(ax, grid="both", open_frame=True):
    """grid behind the data, top / right spines removed"""
    if grid:
        ax.grid(axis=grid, which="major")
    ax.set_axisbelow(True)
    if open_frame:
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)


def save(fig, path):
    fig.savefig(path, bbox_inches="tight", pad_inches=0.03)
    plt.close(fig)
    print("written", path)
