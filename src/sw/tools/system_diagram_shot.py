"""Render the GUI system diagram (About page, jscc_gui.SystemDiagram) off-screen as report/figures/system_diagram.png.

    cd /home/xilinx/claude/rx && QT_QPA_PLATFORM=offscreen python3 /path/to/system_diagram_shot.py   -> /tmp/system_diagram.png

Theme "daylight" on a white background, logical canvas 1920 x 1060. Run on the RX board (CJK fonts of the GUI).
"""
import os, sys
sys.argv = [sys.argv[0], "--lite", "--compact", "--no-gpu3d", "--touch-dev", "off", "--rx", "127.0.0.1", "--theme", "daylight"]
sys.path.insert(0, os.getcwd())
import jscc_gui as G
app = G.QtWidgets.QApplication(sys.argv)
w = G.SystemDiagram(G.serif_family())
w.setAutoFillBackground(True)
pal = w.palette(); pal.setColor(w.backgroundRole(), G.QtGui.QColor("#FFFFFF")); w.setPalette(pal)
w.resize(1920, 1060); w.show()
for _ in range(5): app.processEvents()
w.grab().save("/tmp/system_diagram.png")
print("saved", flush=True)
os._exit(0)
