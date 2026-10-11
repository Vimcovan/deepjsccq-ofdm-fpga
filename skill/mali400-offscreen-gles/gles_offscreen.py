"""Minimal off-screen OpenGL ES 2.0 rendering on a Mali-400 (lima) from Python: GBM + EGL surfaceless context + FBO,
read back as a NumPy RGBA array (top row first). No X / Wayland needed; runs next to an X desktop that only has llvmpipe.

usage:  python3 gles_offscreen.py [W H]      renders a shaded surface, prints renderer + timing, writes gles_test.png
needs:  lima kernel driver loaded (a /dev/dri/renderD* whose driver is "lima"), Mesa with lima_dri.so, libgbm.so.1,
        PyOpenGL (3.1.5 tested), NumPy; Pillow only for saving the PNG.
"""
import ctypes
import os
import sys
import time
import numpy as np

os.environ["PYOPENGL_PLATFORM"] = "egl"          # must be set before the first "import OpenGL"
from OpenGL import EGL, GL                        # do not set OpenGL.ERROR_CHECKING = False: breaks EGL import (3.1.5)

EGL_PLATFORM_GBM_KHR = 0x31D7


def find_render_node(driver="lima"):
    """/dev/dri/renderD* bound to the given kernel driver; the numbering changes (PYNQ's zocl also has one)."""
    for d in sorted(os.listdir("/sys/class/drm")):
        if d.startswith("renderD"):
            drv = os.path.basename(os.path.realpath(f"/sys/class/drm/{d}/device/driver"))
            if drv == driver:
                return f"/dev/dri/{d}"
    raise RuntimeError(f"no render node with driver {driver!r} (kernel module not loaded?)")


class OffscreenGLES:
    def __init__(self, w, h):
        self.fd = os.open(find_render_node(), os.O_RDWR)
        gbm = ctypes.CDLL("libgbm.so.1")
        gbm.gbm_create_device.restype = ctypes.c_void_p
        gbm.gbm_create_device.argtypes = [ctypes.c_int]
        self.gbm = gbm.gbm_create_device(self.fd)
        dpy = EGL.eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, ctypes.c_void_p(self.gbm), None)
        major, minor = EGL.EGLint(), EGL.EGLint()
        if not EGL.eglInitialize(dpy, ctypes.pointer(major), ctypes.pointer(minor)):
            raise RuntimeError("eglInitialize failed")
        EGL.eglBindAPI(EGL.EGL_OPENGL_ES_API)
        attr = (EGL.EGLint * 5)(EGL.EGL_RENDERABLE_TYPE, EGL.EGL_OPENGL_ES2_BIT, EGL.EGL_SURFACE_TYPE, 0, EGL.EGL_NONE)
        cfg, n = EGL.EGLConfig(), EGL.EGLint()
        if not EGL.eglChooseConfig(dpy, attr, ctypes.pointer(cfg), 1, ctypes.pointer(n)) or n.value < 1:
            raise RuntimeError("no EGL config")
        ctx = EGL.eglCreateContext(dpy, cfg, EGL.EGL_NO_CONTEXT, (EGL.EGLint * 3)(EGL.EGL_CONTEXT_CLIENT_VERSION, 2, EGL.EGL_NONE))
        if not EGL.eglMakeCurrent(dpy, EGL.EGL_NO_SURFACE, EGL.EGL_NO_SURFACE, ctx):     # surfaceless
            raise RuntimeError("eglMakeCurrent (surfaceless) failed")
        self.dpy, self.ctx, self.w, self.h = dpy, ctx, w, h
        self.renderer = GL.glGetString(GL.GL_RENDERER).decode()
        # render target: RGBA texture + 16-bit depth renderbuffer
        self.tex = GL.glGenTextures(1)
        GL.glBindTexture(GL.GL_TEXTURE_2D, self.tex)
        GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA, w, h, 0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, None)
        self.rb = GL.glGenRenderbuffers(1)
        GL.glBindRenderbuffer(GL.GL_RENDERBUFFER, self.rb)
        GL.glRenderbufferStorage(GL.GL_RENDERBUFFER, GL.GL_DEPTH_COMPONENT16, w, h)
        self.fbo = GL.glGenFramebuffers(1)
        GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, self.fbo)
        GL.glFramebufferTexture2D(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0, GL.GL_TEXTURE_2D, self.tex, 0)
        GL.glFramebufferRenderbuffer(GL.GL_FRAMEBUFFER, GL.GL_DEPTH_ATTACHMENT, GL.GL_RENDERBUFFER, self.rb)
        if GL.glCheckFramebufferStatus(GL.GL_FRAMEBUFFER) != GL.GL_FRAMEBUFFER_COMPLETE:
            raise RuntimeError("FBO incomplete")
        self.prog = self._program(VS, FS)
        self.a_pos = GL.glGetAttribLocation(self.prog, "pos")
        self.a_col = GL.glGetAttribLocation(self.prog, "col")
        self.u_mvp = GL.glGetUniformLocation(self.prog, "mvp")
        self.vbos = list(GL.glGenBuffers(4))          # one buffer per draw call in a frame (see draw())
        self.ibo = GL.glGenBuffers(1)

    @staticmethod
    def _program(vs, fs):
        p = GL.glCreateProgram()
        for typ, src in ((GL.GL_VERTEX_SHADER, vs), (GL.GL_FRAGMENT_SHADER, fs)):
            s = GL.glCreateShader(typ)
            GL.glShaderSource(s, src)
            GL.glCompileShader(s)
            if not GL.glGetShaderiv(s, GL.GL_COMPILE_STATUS):
                raise RuntimeError(GL.glGetShaderInfoLog(s))
            GL.glAttachShader(p, s)
        GL.glLinkProgram(p)
        if not GL.glGetProgramiv(p, GL.GL_LINK_STATUS):
            raise RuntimeError(GL.glGetProgramInfoLog(p))
        return p

    def begin(self, mvp, bg=(1.0, 1.0, 1.0)):
        """mvp: 4x4 row-major NumPy matrix (clip = mvp @ [x y z 1])."""
        GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, self.fbo)
        GL.glViewport(0, 0, self.w, self.h)
        GL.glClearColor(*bg, 1.0)
        GL.glClear(GL.GL_COLOR_BUFFER_BIT | GL.GL_DEPTH_BUFFER_BIT)
        GL.glEnable(GL.GL_DEPTH_TEST)
        GL.glUseProgram(self.prog)
        flip = np.diag([1.0, -1.0, 1.0, 1.0])          # draw upside down: glReadPixels then returns the top row first
        GL.glUniformMatrix4fv(self.u_mvp, 1, GL.GL_FALSE,  # GLES2 has no transpose flag: pass the transpose
                              np.ascontiguousarray((flip @ mvp).T, np.float32))
        GL.glEnableVertexAttribArray(self.a_pos)
        GL.glEnableVertexAttribArray(self.a_col)
        self._next = 0

    def draw(self, pos, col, mode, idx=None):
        """pos (N, 3), col (N, 4) float; idx uint16 (GLES2 core only guarantees 16-bit indices: N <= 65536).
        Each call uses its own vertex buffer: re-specifying a buffer that an earlier draw of the same frame still
        reads caused a lima GP MMU page fault, after which the context only produced the clear colour."""
        buf = np.ascontiguousarray(np.c_[pos, col], np.float32)
        GL.glBindBuffer(GL.GL_ARRAY_BUFFER, self.vbos[self._next])
        self._next += 1
        GL.glBufferData(GL.GL_ARRAY_BUFFER, buf.nbytes, buf, GL.GL_STREAM_DRAW)
        GL.glVertexAttribPointer(self.a_pos, 3, GL.GL_FLOAT, False, 28, GL.GLvoidp(0))
        GL.glVertexAttribPointer(self.a_col, 4, GL.GL_FLOAT, False, 28, GL.GLvoidp(12))
        if idx is None:
            GL.glDrawArrays(mode, 0, len(pos))
        else:
            idx = np.ascontiguousarray(idx, np.uint16)
            GL.glBindBuffer(GL.GL_ELEMENT_ARRAY_BUFFER, self.ibo)
            GL.glBufferData(GL.GL_ELEMENT_ARRAY_BUFFER, idx.nbytes, idx, GL.GL_STREAM_DRAW)
            GL.glDrawElements(mode, len(idx), GL.GL_UNSIGNED_SHORT, GL.GLvoidp(0))

    def read(self):
        """RGBA uint8 (h, w, 4), top row first. On lima this readback dominates the frame time."""
        img = np.empty((self.h, self.w, 4), np.uint8)
        GL.glReadPixels(0, 0, self.w, self.h, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, img)
        return img


def is_blank(img):
    """True if the frame is a single colour: draw something that is always visible (axes, a frame) so that a broken
    GPU context (only the clear colour comes out) can be detected; then exit and let the parent start a new process."""
    sub = img[::16, ::16, :3].reshape(-1, 3).astype(np.int16)
    return int(np.ptp(sub, axis=0).max()) <= 2


VS = """#version 100
attribute vec3 pos; attribute vec4 col;
uniform mat4 mvp; varying vec4 v_col;
void main() { gl_Position = mvp * vec4(pos, 1.0); v_col = col; }
"""
FS = """#version 100
precision mediump float;
varying vec4 v_col;
void main() { gl_FragColor = v_col; }
"""


def look_at_perspective(w, h, eye, center, fov=45.0, near=0.1, far=100.0):
    f = np.asarray(center, float) - eye; f /= np.linalg.norm(f)
    s = np.cross(f, [0, 0, 1.0]); s /= np.linalg.norm(s)
    u = np.cross(s, f)
    view = np.eye(4); view[0, :3], view[1, :3], view[2, :3] = s, u, -f
    view[:3, 3] = -view[:3, :3] @ eye
    t = 1 / np.tan(np.radians(fov) / 2)
    proj = np.zeros((4, 4)); proj[0, 0] = t * h / w; proj[1, 1] = t
    proj[2, 2] = (far + near) / (near - far); proj[2, 3] = 2 * far * near / (near - far); proj[3, 2] = -1
    return proj @ view


def demo_surface(n=64, phase=0.0):
    """triangles of a shaded z = f(x, y) surface: (pos, col, idx)"""
    x = np.linspace(-1, 1, n, dtype=np.float32)
    X, Y = np.meshgrid(x, x)
    Z = 0.3 * np.sin(4 * X + phase) * np.cos(3 * Y)
    u = (Z - Z.min()) / max(np.ptp(Z), 1e-6)
    col = np.stack([0.2 + 0.8 * u, 0.4 + 0.2 * u, 1.0 - 0.8 * u, np.ones_like(u)], -1).reshape(-1, 4)
    i = np.arange(n * n, dtype=np.uint16).reshape(n, n)
    q = np.stack([i[:-1, :-1], i[1:, :-1], i[:-1, 1:], i[:-1, 1:], i[1:, :-1], i[1:, 1:]], -1).reshape(-1)
    return np.stack([X, Y, Z], -1).reshape(-1, 3), col, q


if __name__ == "__main__":
    w, h = (int(sys.argv[1]), int(sys.argv[2])) if len(sys.argv) > 2 else (940, 430)
    r = OffscreenGLES(w, h)
    print("GL_RENDERER:", r.renderer)
    mvp = look_at_perspective(w, h, eye=np.array([2.2, -2.2, 1.6]), center=[0, 0, 0])
    axes = np.array([[-1, -1, 0], [1, -1, 0], [-1, -1, 0], [-1, 1, 0], [-1, -1, 0], [-1, -1, 0.6]], np.float32)
    t_draw, t_read = [], []
    for k in range(12):
        t0 = time.perf_counter()
        pos, col, q = demo_surface(phase=0.3 * k)
        r.begin(mvp)
        r.draw(pos, col, GL.GL_TRIANGLES, q)
        r.draw(axes, np.tile([0, 0, 0, 1.0], (len(axes), 1)), GL.GL_LINES)
        GL.glFinish()
        t1 = time.perf_counter()
        img = r.read()
        t2 = time.perf_counter()
        if k >= 2:                                    # skip warm-up frames
            t_draw.append((t1 - t0) * 1e3); t_read.append((t2 - t1) * 1e3)
    print(f"{w}x{h}: geometry + draw {np.mean(t_draw):.1f} ms, glReadPixels {np.mean(t_read):.1f} ms, blank={is_blank(img)}")
    try:
        from PIL import Image
        Image.fromarray(img, "RGBA").save("gles_test.png")
        print("wrote gles_test.png")
    except ImportError:
        pass
