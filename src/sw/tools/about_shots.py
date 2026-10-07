"""Off-screen renders of the About page (every topic) at the board screen size, for checking the layout.

    QT_QPA_PLATFORM=offscreen python3 about_shots.py [outdir] [--theme name]
"""
import os
import sys
outdir = next((a for a in sys.argv[1:] if not a.startswith("--") and not sys.argv[sys.argv.index(a) - 1] == "--theme"), "/tmp/about")
sys.argv = [sys.argv[0], "--lite", "--compact", "--no-gpu3d", "--touch-dev", "off", "--rx", "127.0.0.1"] + \
    (["--theme", sys.argv[sys.argv.index("--theme") + 1]] if "--theme" in sys.argv else [])
import jscc_gui as G                                   # noqa: E402  (parses the argv above)
app = G.QtWidgets.QApplication(sys.argv)
g = G.Gui(); g.resize(1024, 600); g.show()
os.makedirs(outdir, exist_ok=True)
g.tabs.setCurrentIndex(3)
about = g.tabs.widget(3)
def shot(name):
    for _ in range(5):
        app.processEvents()
    g.grab().save(os.path.join(outdir, name))


for k in range(len(G.ABOUT_TOPICS) + 1):
    about.show_topic(k); shot(f"about_{k}.png")
about.show_topic(5); about.zoom_in(os.path.join(G.ASSETS, "about", "compare_table.png")); shot("about_zoom.png")
print("saved to", outdir, flush=True)
os._exit(0)
