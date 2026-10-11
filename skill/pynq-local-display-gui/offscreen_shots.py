"""Render a PyQt5 window off-screen at the real screen size, save a screenshot of every tab, and report labels / buttons
whose text does not fit. Run it ON THE BOARD (same fonts, Qt and DPI as the real screen).

    python3 offscreen_shots.py <module> <WindowClass> <W> <H> [outdir] [-- args for the GUI]
    e.g.  python3 offscreen_shots.py my_gui MainWindow 1024 600 /tmp/shots -- --fullscreen

<module> is imported from the current directory; <WindowClass>() must build the window without arguments
(the GUI's own command-line arguments, if it parses sys.argv, go after "--").
"""
import importlib
import os
import sys
import time

os.environ["QT_QPA_PLATFORM"] = "offscreen"
sys.dont_write_bytecode = True                              # no __pycache__ left next to the GUI copy
argv = sys.argv[1:]
gui_args = argv[argv.index("--") + 1:] if "--" in argv else []
argv = argv[:argv.index("--")] if "--" in argv else argv
if len(argv) < 4:
    sys.exit(__doc__)
mod_name, cls_name, W, H = argv[0], argv[1], int(argv[2]), int(argv[3])
outdir = argv[4] if len(argv) > 4 else "/tmp/shots"

sys.path.insert(0, os.getcwd())
sys.argv = [mod_name + ".py"] + gui_args
from PyQt5 import QtWidgets  # noqa: E402

app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(sys.argv)
mod = importlib.import_module(mod_name)
win = getattr(mod, cls_name)()
win.resize(W, H)
win.show()
os.makedirs(outdir, exist_ok=True)


def settle(seconds=0.3):
    """let layouts, timers and animations run before grabbing"""
    t0 = time.time()
    while True:
        app.processEvents()
        if time.time() - t0 >= seconds:
            break
        time.sleep(0.01)


def overflow():
    """visible QLabel / QAbstractButton whose single-line plain text is wider than the widget"""
    bad = []
    for w in win.findChildren((QtWidgets.QLabel, QtWidgets.QAbstractButton)):
        if not w.isVisible():
            continue
        text = w.text()
        if not text or "<" in text or (isinstance(w, QtWidgets.QLabel) and w.wordWrap()):
            continue                                        # rich text / wrapped labels: check on the screenshot
        need = w.fontMetrics().horizontalAdvance(text.replace("&", ""))
        have = w.contentsRect().width()
        if isinstance(w, QtWidgets.QAbstractButton):
            have -= 8                                       # rough frame / padding of a push button
        if need > have:
            bad.append((w.objectName() or type(w).__name__, text, need, have))
    return bad


def shot(name):
    settle()
    path = os.path.join(outdir, name)
    win.grab().save(path)
    print("saved", path)
    for obj, text, need, have in overflow():
        print(f"  OVERFLOW {obj}: {text!r} needs {need} px, has {have} px")


shot("window.png")
for t, tabs in enumerate(win.findChildren(QtWidgets.QTabWidget)):
    for i in range(tabs.count()):
        tabs.setCurrentIndex(i)
        shot(f"tabs{t}_{i}_{tabs.tabText(i).strip().replace(' ', '_').replace('/', '_') or i}.png")
print("done:", outdir, flush=True)
os._exit(0)                                                 # skip Qt teardown (worker threads, GPU contexts)
