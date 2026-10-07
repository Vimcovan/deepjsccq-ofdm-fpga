"""Off-screen 3-D |H| surface on the Mali-400 (lima) for the board display.

The board's X server (armsoc DDX) only gives llvmpipe to GLX clients, so this process renders with OpenGL ES 2.0
on the lima render node directly (GBM + EGL, surfaceless context, FBO) and returns the RGBA image; the GUI shows it
as a picture and paints the axis labels itself, using camera() / project() from this module.

protocol on stdin / stdout (little endian):
  request   "H3DR" W H T N zlo zhi (<4s4I2f) + T*N float32 |H| dB (rows oldest..newest) + T float32 times (s, <= 0)
  response  "H3DI" W H render_ms (<4s2If) + W*H*4 bytes RGBA, top row first
usage: python3 h3d_render.py            (server, started by jscc_gui.py --lite)
       python3 h3d_render.py --selftest (renders a test surface, prints timing, writes h3d_selftest.png)
"""
import os
import struct
import sys
import time
import numpy as np

T_WIN, T_SPAN, Z_SCALE, XE = 5.0, 50.0, 5.0, 28.0
ELEV, AZIM, DIST, FOV = 26.0, -55.0, 140.0, 60.0
# colours: "--colors" JSON from jscc_gui.py (bg, cmap, grid, mesh as 0..255), default = the light theme
_C = dict(bg=[0xFA, 0xF9, 0xF5], cmap=[[232, 230, 220], [217, 119, 87], [120, 52, 30]], grid=[61, 57, 41], mesh=[115, 51, 28, 255])
if "--colors" in sys.argv:
    import json
    _C.update(json.loads(sys.argv[sys.argv.index("--colors") + 1]))
BG = tuple(v / 255 for v in _C["bg"])
CMAP = np.array(_C["cmap"], np.float32) / 255
INK, INK_L = tuple(v / 255 for v in _C["grid"]) + (1.0,), tuple(v / 255 for v in _C["grid"]) + (0.2,)
MESH = tuple(v / 255 for v in _C["mesh"][:3]) + (_C["mesh"][3] / 255 if len(_C["mesh"]) > 3 else 1.0,)
REQ, RSP = struct.Struct("<4s4I2f"), struct.Struct("<4s2If")


# ------------------------------------------------------------------ camera (shared with the GUI for the labels)
def camera(w, h, zlo, zhi):
    """4x4 model-view-projection (row-major numpy) of the pyqtgraph view used on the PC GUI."""
    c = np.array([0.0, -T_SPAN / 2, (zlo + zhi) / 2 * Z_SCALE])
    e, a = np.radians(ELEV), np.radians(AZIM)
    eye = c + DIST * np.array([np.cos(e) * np.cos(a), np.cos(e) * np.sin(a), np.sin(e)])
    f = c - eye; f /= np.linalg.norm(f)
    s = np.cross(f, [0, 0, 1.0]); s /= np.linalg.norm(s)
    u = np.cross(s, f)
    view = np.eye(4); view[0, :3], view[1, :3], view[2, :3] = s, u, -f
    view[:3, 3] = -view[:3, :3] @ eye
    n, fa = 1.0, 1000.0
    t = 1 / np.tan(np.radians(FOV) / 2)
    a = min(w / h, 2.2)                      # FOV is horizontal (as in pyqtgraph) up to aspect 2.2; wider views
    proj = np.zeros((4, 4)); proj[1, 1] = t * a; proj[0, 0] = proj[1, 1] * h / w   # keep the vertical framing
    proj[2, 2] = (fa + n) / (n - fa); proj[2, 3] = 2 * fa * n / (n - fa); proj[3, 2] = -1
    m = proj @ view
    # zoom / centre so the box with the axis labels fills the viewport (pad in pixels for the label text)
    box = np.array([(x, y, z) for x in (-XE, XE + 12) for y in (-T_SPAN - 10, 7)
                    for z in (zlo * Z_SCALE, zhi * Z_SCALE + 6)])
    q = np.c_[box, np.ones(len(box))] @ m.T
    ndc = q[:, :2] / q[:, 3:4]
    lo, hi = ndc.min(0), ndc.max(0)
    px, py = 2 * 34 / w, 2 * 12 / h                    # half label width / height in NDC
    k = min((2 - 2 * px) / (hi[0] - lo[0]), (2 - 2 * py) / (hi[1] - lo[1]))
    fit = np.eye(4); fit[0, 0] = fit[1, 1] = k
    fit[:2, 3] = -k * (lo + hi) / 2                     # clip space x' = k x + b w  ->  NDC x' = k x + b
    return fit @ m


def project(mvp, pts, w, h):
    """world points (N, 3) -> pixel coordinates (N, 2), origin top-left."""
    p = np.c_[np.asarray(pts, float), np.ones(len(pts))] @ mvp.T
    ndc = p[:, :3] / p[:, 3:4]
    return np.c_[(ndc[:, 0] + 1) / 2 * w, (1 - ndc[:, 1]) / 2 * h]


# ------------------------------------------------------------------ GLES2 renderer
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


class Renderer:
    def __init__(self):
        os.environ["PYOPENGL_PLATFORM"] = "egl"
        import ctypes
        from OpenGL import EGL, GL           # (OpenGL.ERROR_CHECKING = False breaks PyOpenGL 3.1.5's EGL import)
        self.GL, self.EGL = GL, EGL
        node = next(f"/dev/dri/{d}" for d in sorted(os.listdir("/sys/class/drm")) if d.startswith("renderD")
                    and os.path.basename(os.path.realpath(f"/sys/class/drm/{d}/device/driver")) == "lima")
        self.fd = os.open(node, os.O_RDWR)
        gbm = ctypes.CDLL("libgbm.so.1")
        gbm.gbm_create_device.restype = ctypes.c_void_p; gbm.gbm_create_device.argtypes = [ctypes.c_int]
        self.gbm = gbm.gbm_create_device(self.fd)
        dpy = EGL.eglGetPlatformDisplay(0x31D7, ctypes.c_void_p(self.gbm), None)        # EGL_PLATFORM_GBM_KHR
        major, minor = EGL.EGLint(), EGL.EGLint()
        if not EGL.eglInitialize(dpy, ctypes.pointer(major), ctypes.pointer(minor)):
            raise RuntimeError("eglInitialize failed")
        EGL.eglBindAPI(EGL.EGL_OPENGL_ES_API)
        attr = (EGL.EGLint * 5)(EGL.EGL_RENDERABLE_TYPE, EGL.EGL_OPENGL_ES2_BIT, EGL.EGL_SURFACE_TYPE, 0, EGL.EGL_NONE)
        cfg, n = EGL.EGLConfig(), EGL.EGLint()
        if not EGL.eglChooseConfig(dpy, attr, ctypes.pointer(cfg), 1, ctypes.pointer(n)) or n.value < 1:
            raise RuntimeError("no EGL config")
        cattr = (EGL.EGLint * 3)(EGL.EGL_CONTEXT_CLIENT_VERSION, 2, EGL.EGL_NONE)
        ctx = EGL.eglCreateContext(dpy, cfg, EGL.EGL_NO_CONTEXT, cattr)
        if not EGL.eglMakeCurrent(dpy, EGL.EGL_NO_SURFACE, EGL.EGL_NO_SURFACE, ctx):
            raise RuntimeError("eglMakeCurrent (surfaceless) failed")
        self.dpy, self.ctx = dpy, ctx
        self.renderer = GL.glGetString(GL.GL_RENDERER).decode()
        self.prog = self._program()
        self.a_pos = GL.glGetAttribLocation(self.prog, "pos"); self.a_col = GL.glGetAttribLocation(self.prog, "col")
        self.u_mvp = GL.glGetUniformLocation(self.prog, "mvp")
        self.vbo, self.ibo, self.vbo_l = GL.glGenBuffers(3)      # surface and lines in separate buffers (see draw)
        self.size, self.fbo = None, None

    def _program(self):
        GL = self.GL
        p = GL.glCreateProgram()
        for typ, src in ((GL.GL_VERTEX_SHADER, VS), (GL.GL_FRAGMENT_SHADER, FS)):
            s = GL.glCreateShader(typ); GL.glShaderSource(s, src); GL.glCompileShader(s)
            if not GL.glGetShaderiv(s, GL.GL_COMPILE_STATUS):
                raise RuntimeError(GL.glGetShaderInfoLog(s))
            GL.glAttachShader(p, s)
        GL.glLinkProgram(p)
        if not GL.glGetProgramiv(p, GL.GL_LINK_STATUS):
            raise RuntimeError(GL.glGetProgramInfoLog(p))
        return p

    def _target(self, w, h):
        GL = self.GL
        if self.size == (w, h):
            return
        if self.fbo is not None:
            GL.glDeleteFramebuffers(1, [self.fbo]); GL.glDeleteTextures([self.tex]); GL.glDeleteRenderbuffers(1, [self.rb])
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
        self.size = (w, h)

    @staticmethod
    def geometry(hdb, ts, zlo, zhi):
        """triangles (surface, lit) + lines (grid on the surface, floor grid, axes) as (pos, col) float32 arrays."""
        T, N = hdb.shape
        x = np.arange(N, dtype=np.float32) - N // 2                                   # subcarrier -26..25 (52 used)
        x = np.where(x >= 0, x + 1, x)                                                 # no DC: -26..-1, 1..26
        y = (np.asarray(ts, np.float32) / T_WIN * T_SPAN)
        X, Y = np.meshgrid(x, y)
        Z = hdb.astype(np.float32) * Z_SCALE
        P = np.stack([X, Y, Z], -1)
        # shading: lambert on the surface normal (finite differences), light from the camera side, above
        dzx = np.gradient(Z, x, axis=1); dzy = np.gradient(Z, y, axis=0) if T > 1 else np.zeros_like(Z)
        nrm = np.stack([-dzx, -dzy, np.ones_like(Z)], -1); nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
        light = np.array([0.35, -0.55, 0.76], np.float32); light /= np.linalg.norm(light)
        shade = 0.62 + 0.38 * np.clip(nrm @ light, 0, 1)
        u = np.clip((hdb - zlo) / max(zhi - zlo, 1e-6), 0, 1).astype(np.float32)
        k = np.minimum((u * 2).astype(int), 1); f = (u * 2 - k)[..., None]
        C = (CMAP[k] * (1 - f) + CMAP[k + 1] * f) * shade[..., None]
        tri_pos = P.reshape(-1, 3); tri_col = np.c_[C.reshape(-1, 3), np.ones(T * N, np.float32)]
        i = np.arange(T * N, dtype=np.uint16).reshape(T, N)
        q = np.stack([i[:-1, :-1], i[1:, :-1], i[:-1, 1:], i[:-1, 1:], i[1:, :-1], i[1:, 1:]], -1).reshape(-1)
        # lines: every 13th subcarrier along time, every 0.5 s along subcarriers, floor grid, z axis
        L, LC = [], []
        ink, ink_l, clay = INK, INK_L, MESH
        zf = zlo * Z_SCALE
        lift = np.array([0, 0, 0.15], np.float32)
        cols = [j for j in range(N) if int(x[j]) in (-26, -13, -1, 1, 13, 26)]
        step = max(1, int(round(0.5 / (T_WIN / max(T - 1, 1)))))
        rows = list(range(T - 1, -1, -step))
        seg = [np.stack([P[:-1, cols], P[1:, cols]], 2).reshape(-1, 3),                # along time, 6 subcarriers
               np.stack([P[rows, :-1], P[rows, 1:]], 2).reshape(-1, 3)]                # along subcarriers, every 0.5 s
        surf_l = np.concatenate(seg) + lift
        for sc in (-26, -13, 0, 13, 26):
            L += [(sc, -T_SPAN, zf), (sc, 0, zf)]; LC += [ink_l, ink_l]
        for s in range(0, int(T_WIN) + 1):
            yy = -s * T_SPAN / T_WIN
            L += [(-XE, yy, zf), (XE, yy, zf)]; LC += [ink_l, ink_l]
        L += [(-XE, -T_SPAN, zf), (XE, -T_SPAN, zf), (XE, -T_SPAN, zf), (XE, 0, zf), (XE, 0, zf), (XE, 0, zhi * Z_SCALE)]
        LC += [ink] * 6
        for zz in range(int(np.ceil(zlo)), int(np.floor(zhi)) + 1):
            L += [(XE, 0, zz * Z_SCALE), (XE + 1.5, 0, zz * Z_SCALE)]; LC += [ink, ink]
        lp = np.concatenate([surf_l, np.array(L, np.float32)])
        lc = np.concatenate([np.tile(np.array(clay, np.float32), (len(surf_l), 1)), np.array(LC, np.float32)])
        return tri_pos, tri_col, q, lp.astype(np.float32), lc

    def render(self, w, h, hdb, ts, zlo, zhi):
        GL = self.GL
        t0 = time.perf_counter()
        self._target(w, h)
        tp, tc, q, lp, lc = self.geometry(hdb, ts, zlo, zhi)
        GL.glViewport(0, 0, w, h)
        GL.glClearColor(*BG, 1.0); GL.glClear(GL.GL_COLOR_BUFFER_BIT | GL.GL_DEPTH_BUFFER_BIT)
        GL.glEnable(GL.GL_DEPTH_TEST); GL.glEnable(GL.GL_BLEND)
        GL.glBlendFunc(GL.GL_SRC_ALPHA, GL.GL_ONE_MINUS_SRC_ALPHA)
        GL.glUseProgram(self.prog)
        mvp = np.diag([1.0, -1.0, 1.0, 1.0]) @ camera(w, h, zlo, zhi)          # drawn upside down: glReadPixels
        GL.glUniformMatrix4fv(self.u_mvp, 1, GL.GL_FALSE,                       # then yields top row first
                              np.ascontiguousarray(mvp.T, np.float32))       # GLES2: no transpose flag
        GL.glEnableVertexAttribArray(self.a_pos); GL.glEnableVertexAttribArray(self.a_col)

        # one vertex buffer per draw call: re-specifying a buffer that the previous draw of this frame still reads
        # led to a lima GP MMU page fault (2026-10-05), after which the context only produced the clear colour
        def draw(pos, col, mode, idx=None, vbo=None):
            buf = np.ascontiguousarray(np.c_[pos, col], np.float32)
            GL.glBindBuffer(GL.GL_ARRAY_BUFFER, vbo or self.vbo)
            GL.glBufferData(GL.GL_ARRAY_BUFFER, buf.nbytes, buf, GL.GL_STREAM_DRAW)
            GL.glVertexAttribPointer(self.a_pos, 3, GL.GL_FLOAT, False, 28, GL.GLvoidp(0))
            GL.glVertexAttribPointer(self.a_col, 4, GL.GL_FLOAT, False, 28, GL.GLvoidp(12))
            if idx is None:
                GL.glDrawArrays(mode, 0, len(pos))
            else:
                GL.glBindBuffer(GL.GL_ELEMENT_ARRAY_BUFFER, self.ibo)
                GL.glBufferData(GL.GL_ELEMENT_ARRAY_BUFFER, idx.nbytes, idx, GL.GL_STREAM_DRAW)
                GL.glDrawElements(mode, len(idx), GL.GL_UNSIGNED_SHORT, GL.GLvoidp(0))

        GL.glEnable(GL.GL_POLYGON_OFFSET_FILL); GL.glPolygonOffset(1.0, 1.0)            # lines on top of the surface
        if len(q):
            draw(tp, tc, GL.GL_TRIANGLES, q)
        GL.glDisable(GL.GL_POLYGON_OFFSET_FILL)
        GL.glLineWidth(1.5)
        draw(lp, lc, GL.GL_LINES, vbo=self.vbo_l)
        buf = np.empty((h, w, 4), np.uint8)
        GL.glReadPixels(0, 0, w, h, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, buf)     # ~45 ms for 940x430 on lima
        return buf, (time.perf_counter() - t0) * 1e3


def read_exact(f, n):
    b = bytearray()
    while len(b) < n:
        chunk = f.read(n - len(b))
        if not chunk:
            raise EOFError
        b += chunk
    return bytes(b)


def serve():
    r = Renderer()
    print(f"h3d_render: {r.renderer}", file=sys.stderr, flush=True)
    fin, fout = sys.stdin.buffer, sys.stdout.buffer
    blank = 0

    def is_blank(img):                       # the axes are always drawn: one single colour = broken context
        sub = img[::16, ::16, :3].reshape(-1, 3).astype(np.int16)
        return int(np.ptp(sub, axis=0).max()) <= 2

    # warm-up: one frame at start, so a context that is broken from the first draw is found at boot, not on stage
    T0, N0 = 25, 52
    ts0 = np.linspace(-T_WIN, 0, T0).astype(np.float32)
    h0 = (np.sin(np.arange(N0) / 6.0)[None, :] * np.ones((T0, 1))).astype(np.float32)
    for _ in range(2):
        img0, _ = r.render(640, 360, h0, ts0, -2.0, 1.0)
    if is_blank(img0):
        print("h3d_render: blank warm-up frame (GPU context broken), exiting", file=sys.stderr, flush=True)
        return
    while True:
        try:
            magic, w, h, T, N, zlo, zhi = REQ.unpack(read_exact(fin, REQ.size))
        except EOFError:
            return
        hdb = np.frombuffer(read_exact(fin, T * N * 4), np.float32).reshape(T, N)
        ts = np.frombuffer(read_exact(fin, T * 4), np.float32)
        img, ms = r.render(w, h, hdb, ts, zlo, zhi)
        fout.write(RSP.pack(b"H3DI", w, h, ms)); fout.write(memoryview(img).cast("B")); fout.flush()
        # watchdog: the axes are always drawn, so a frame of pure clear colour means the GPU context is broken
        # (lima after a GP fault): exit, the GUI starts a new renderer
        blank = blank + 1 if is_blank(img) else 0
        if blank >= 3:
            print("h3d_render: blank output (GPU context lost), restarting", file=sys.stderr, flush=True)
            return


def selftest():
    r = Renderer()
    print("renderer:", r.renderer)
    T, N, w, h = 50, 52, 940, 430
    ts = np.linspace(-T_WIN, 0, T)
    k = np.arange(N)
    hdb = (np.sin(k / 6.0)[None, :] * 1.2 - 0.6 + 0.3 * np.sin(ts[:, None] * 2)).astype(np.float32)
    for _ in range(3):
        img, ms = r.render(w, h, hdb, ts, -2.0, 1.0)
    times = [r.render(w, h, hdb, ts, -2.0, 1.0)[1] for _ in range(10)]
    print(f"render + readback {w}x{h}: mean {np.mean(times):.1f} ms, max {np.max(times):.1f} ms")
    from PIL import Image
    Image.fromarray(img, "RGBA").save("h3d_selftest.png")


if __name__ == "__main__":
    selftest() if "--selftest" in sys.argv else serve()
