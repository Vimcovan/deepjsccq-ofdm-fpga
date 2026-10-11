"""Template: render a PyQt5 GUI off-screen at the target screen size and save screenshots of chosen states.

    QT_QPA_PLATFORM=offscreen python3 offscreen_shots.py [outdir]

Run it on the target board (same fonts, same Qt, same DPI as the real screen) — rendering on a PC with other fonts
does not tell whether a label fits. Adapt the three marked places to your program.
"""
import os
import sys
import time

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
outdir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/shots"
W, H = 1024, 600                                         # (1) target screen size

sys.argv = [sys.argv[0], "--lite"]                       # (2) the arguments your GUI parses at import / start-up
import my_gui as G                                       # noqa: E402  (3) your GUI module and main window class

app = G.QtWidgets.QApplication(sys.argv)
win = G.MainWindow()
win.resize(W, H)
win.show()
os.makedirs(outdir, exist_ok=True)


def settle(seconds=0.0):
    """let layouts, timers and animations run before grabbing"""
    t0 = time.time()
    while True:
        app.processEvents()
        if time.time() - t0 >= seconds:
            break
        time.sleep(0.01)


def shot(name, seconds=0.0):
    settle(seconds)
    win.grab().save(os.path.join(outdir, name))


# --- states to check: every tab / page / dialog / worst-case text ------------------------------------------------
for i in range(win.tabs.count()):
    win.tabs.setCurrentIndex(i)
    shot(f"tab_{i}.png")

# worst-case label text: measure instead of guessing
fm = G.QtGui.QFontMetrics(win.font())
for text in ("RX · CRC error", "RX · decode failed"):
    print(f"{text!r}: {fm.horizontalAdvance(text)} px")

print("saved to", outdir, flush=True)
os._exit(0)                                              # skip Qt teardown (threads, GPU contexts)
