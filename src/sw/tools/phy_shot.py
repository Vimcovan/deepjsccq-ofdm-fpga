"""Off-screen render of the PHY detail page with live data from the local rx_server, at the board screen size.

    cd /home/xilinx/claude/rx && QT_QPA_PLATFORM=offscreen python3 /path/to/phy_shot.py [out.png] [--theme daylight] [--wait 8] [--no-gpu3d]

Runs next to the normal GUI (rx_server serves several subscribers). Used for the poster.
"""
import os
import sys
import time

argv = sys.argv[1:]
out = next((a for i, a in enumerate(argv) if not a.startswith("--") and (i == 0 or argv[i - 1] not in ("--theme", "--wait"))),
           "/tmp/phy_page.png")
theme = argv[argv.index("--theme") + 1] if "--theme" in argv else "daylight"
wait = float(argv[argv.index("--wait") + 1]) if "--wait" in argv else 8.0
sys.argv = [sys.argv[0], "--lite", "--compact", "--touch-dev", "off", "--rx", "127.0.0.1", "--theme", theme] + \
    (["--no-gpu3d"] if "--no-gpu3d" in argv else [])
sys.path.insert(0, os.getcwd())
import jscc_gui as G                                   # noqa: E402  (parses the argv above)

app = G.QtWidgets.QApplication(sys.argv)
g = G.Gui(); g.resize(1024, 600); g.show()
g.tabs.setCurrentIndex(1)                              # PHY detail
t0 = time.time()
while time.time() - t0 < wait:
    app.processEvents(); time.sleep(0.01)
g.grab().save(out)
print("saved", out, flush=True)
os._exit(0)
