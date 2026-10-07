"""Print which OpenGL implementation Qt gets (renderer / version) on the current platform."""
import sys
from PyQt5 import QtGui, QtWidgets
app = QtWidgets.QApplication(sys.argv)
fmt = QtGui.QSurfaceFormat()
if "desktop" in sys.argv:                    # request desktop OpenGL (compatibility, 2.1) instead of the platform default
    fmt.setRenderableType(QtGui.QSurfaceFormat.OpenGL); fmt.setVersion(2, 1)
surf = QtGui.QOffscreenSurface(); surf.setFormat(fmt); surf.create()
ctx = QtGui.QOpenGLContext(); ctx.setFormat(fmt)
print("context created:", ctx.create())
print("make current:", ctx.makeCurrent(surf))
from OpenGL import GL
for n in ("GL_VENDOR", "GL_RENDERER", "GL_VERSION"):
    print(f"{n:12s}", GL.glGetString(getattr(GL, n)))
print("isOpenGLES:", ctx.isOpenGLES())
