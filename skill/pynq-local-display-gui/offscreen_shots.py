"""Render a PyQt5 window at the real screen size WITHOUT showing it, save a screenshot of every tab, and report labels /
buttons whose text does not fit. Run it ON THE BOARD.

    python3 offscreen_shots.py <module> <WindowClass> <W> <H> [outdir] [-- args for the GUI]
    e.g.  python3 offscreen_shots.py my_gui MainWindow 1024 600 /tmp/gui_check/shots -- --fullscreen

Default: connects to the board's X server (DISPLAY, default :0, XAUTHORITY default /root/.Xauthority) with the window
flag WA_DontShowOnScreen, so fonts and DPI are exactly those of the real screen but nothing appears on it. Qt's
"offscreen" platform is only a fallback when no X server is reachable: it uses its own default font (measured on
PYNQ-ZU: 12 pt / 17 px instead of the X session's 9 pt / 12 px), so text widths come out ~40 % too large.
Also prints the window manager's work area (_NET_WORKAREA): a non-fullscreen window plus its title bar must fit in it.
<module> is imported from the current directory; <WindowClass>() must build the window without arguments.
"""
import importlib
import os
import subprocess
import sys
import time

sys.dont_write_bytecode = True                              # no __pycache__ left next to the GUI copy
argv = sys.argv[1:]
gui_args = argv[argv.index("--") + 1:] if "--" in argv else []
argv = argv[:argv.index("--")] if "--" in argv else argv
if len(argv) < 4:
    sys.exit(__doc__)
mod_name, cls_name, W, H = argv[0], argv[1], int(argv[2]), int(argv[3])
outdir = argv[4] if len(argv) > 4 else "/tmp/gui_check/shots"

os.environ.setdefault("DISPLAY", ":0")
os.environ.setdefault("XAUTHORITY", "/root/.Xauthority")
x_ok = subprocess.run(["xset", "-q"], capture_output=True).returncode == 0 if "QT_QPA_PLATFORM" not in os.environ else False
if not x_ok and os.environ.get("QT_QPA_PLATFORM") != "xcb":
    os.environ["QT_QPA_PLATFORM"] = "offscreen"
    print("WARNING: no X server reachable -> Qt offscreen platform; its default font differs from the real screen, "
          "text widths are NOT reliable")

sys.path.insert(0, os.getcwd())
sys.argv = [mod_name + ".py"] + gui_args
from PyQt5 import QtCore, QtGui, QtWidgets  # noqa: E402

app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(sys.argv)
f = app.font()
print(f"platform {app.platformName()}, default font {f.family()} {f.pointSizeF()} pt -> "
      f"{QtGui.QFontInfo(f).pixelSize()} px, dpi {app.primaryScreen().logicalDotsPerInch():.1f}")
if x_ok:
    wa = subprocess.run(["xprop", "-root", "_NET_WORKAREA"], capture_output=True, text=True).stdout.strip()
    print("window manager work area:", wa.split("=")[-1].strip() if "=" in wa else "n/a (no EWMH window manager?)")
    try:
        x, y, ww, wh = [int(v) for v in wa.split("=")[-1].split(",")[:4]]
        if H > wh:
            print(f"  WARNING: window height {H} > work area height {wh}: with a title bar the top of a "
                  f"non-fullscreen window (tab bar, menus) is pushed off-screen -> use showFullScreen() or a smaller size")
    except ValueError:
        pass
mod = importlib.import_module(mod_name)
win = getattr(mod, cls_name)()
win.setAttribute(QtCore.Qt.WA_DontShowOnScreen, True)       # laid out and rendered, never mapped on the X screen
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
            have -= 2 * w.style().pixelMetric(QtWidgets.QStyle.PM_ButtonMargin)
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
