"""Off-screen frames of the Clawd easter egg (About page, 5 taps on the title), for checking.

    QT_QPA_PLATFORM=offscreen python3 clawd_shots.py [outdir]
"""
import os
import sys
import time
outdir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/clawd"
sys.argv = [sys.argv[0], "--lite", "--compact", "--no-gpu3d", "--touch-dev", "off", "--rx", "127.0.0.1"]
import jscc_gui as G                                   # noqa: E402
app = G.QtWidgets.QApplication(sys.argv)
g = G.Gui(); g.resize(1024, 600); g.show()
os.makedirs(outdir, exist_ok=True)
g.tabs.setCurrentIndex(3); about = g.tabs.widget(3)
for _ in range(5):
    about.title.mousePressEvent(None)                  # five quick taps
t0 = time.time()
for t in (1.5, 3.9, 4.4, 5.5, 8.0, 9.5):
    while time.time() - t0 < t:
        app.processEvents(); time.sleep(0.01)
    g.grab().save(os.path.join(outdir, f"clawd_{t:.1f}.png"))
print("saved to", outdir, flush=True)
os._exit(0)
