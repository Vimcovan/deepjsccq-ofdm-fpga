---
name: mali400-offscreen-gles
description: Enable and use the Mali-400 GPU of a Zynq UltraScale+ (ZU EG/EV) board running PYNQ or another Ubuntu-based Linux, through the open-source lima driver, and render with OpenGL ES 2.0 off-screen from Python (GBM + EGL surfaceless + FBO + glReadPixels). Use when the user wants GPU / OpenGL / 3-D plotting / hardware-accelerated drawing on a ZynqMP board, mentions Mali or lima, or complains that OpenGL or 3-D plots on the board are slow / only get llvmpipe software rendering.
argument-hint: "[ssh-target, e.g. root@192.168.3.1]"
---

# Mali-400 Off-screen OpenGL ES 2.0 on Zynq UltraScale+

## Purpose

Find out whether the board's Mali-400 can be used, get the lima kernel driver running if it is missing, and render
off-screen with OpenGL ES 2.0 from Python, returning RGBA images that any GUI (Qt, web page, video stream) can display.

**Expected outcome:** a probe report (driver / device tree / user space), a smoke-test PNG rendered by `Mali400`
with measured draw and readback times, and — if requested — a renderer process integrated into the user's program.

**Prerequisites:**
- Shell access to the board (local terminal or `ssh <target>`), root for driver steps
- Zynq UltraScale+ **EG or EV** device (CG parts have no GPU)
- Python 3 with NumPy and PyOpenGL on the board; Pillow only for saving PNGs

---

## When to Use

- 3-D / OpenGL drawing on the board is slow, and `GL_RENDERER` is `llvmpipe`
- The user wants a GPU-rendered plot or image inside an existing GUI on the board
- The user asks whether the ZynqMP GPU can be used under PYNQ / Ubuntu

## When NOT to Use

- PetaLinux with Xilinx's proprietary `libmali` driver → that stack has its own EGL/GLES libraries; do not mix in lima
- Zynq-7000, ZU CG, Versal → no Mali-400
- Pure 2-D GUI work that already runs fast on the CPU

---

## DO's

- **Track every file you copy to the board and delete it whenever you stop** — before the summary, at a USER GATE, and
  before any clarifying question (scripts, copies of the user's program, screenshots, error logs in `/tmp`)
- Stay inside the workspace and the board paths the user named; do not search other directories on the PC for the user's files — ask
- Run the read-only probe (Step 1) before changing anything
- Find the GPU render node **by driver name** (`lima`), never by number
- Render in a **separate process**; the GUI only displays the returned image
- Keep the render size equal to the displayed size and the refresh rate as low as the content needs
- Draw something that is always visible (axes, a frame) so a broken context can be detected

## DON'Ts

- **Never kill processes by name** on the PC or the board (`Stop-Process -Name ssh`, `Get-Process ssh | Stop-Process`, `pkill ssh`, `killall python3`) — other sessions use them; stop only a process you started, by its exact PID
- **Copy commands name the remote side explicitly**: `scp <local file> <target>:<remote dir>/` and `scp <target>:<remote file> <local dir>/`; never pass a local credential (the `-i` key, anything under `~/.ssh`) as a source or destination, and never write into `~/.ssh`
- **Never assume `/dev/dri/renderD128` is the GPU** — on PYNQ it can belong to `zocl` (XRT)
- **Never insmod, write `/lib/modules`, or create `/etc/modules-load.d` files without the user's go-ahead** (USER GATE 1 / 2)
- **Never try to make X use the GPU** — see the "Paths that do not work" table; do not spend time re-testing them
- **Never use pyqtgraph.opengl / legacy desktop GL** on this stack — only OpenGL ES 2.0 is available
- **Never re-fill (`glBufferData`) a vertex buffer that an earlier draw of the same frame still uses** — one buffer per draw call
- **Never set `OpenGL.ERROR_CHECKING = False`** with PyOpenGL 3.1.5 — the EGL module then fails to import

> **Anti-pattern:** before lima was ever loaded, the agent listed `/dev/dri`, saw `renderD128` and reported "the board
> has a GPU render node". The node belonged to `zocl`. **Always print the driver of every render node.**

> **Anti-pattern:** after a lima GP MMU page fault the renderer kept running without any error, but every frame was
> only the clear colour; nothing in the process signalled the failure. **A single-colour frame means the context is
> broken — detect it and restart the renderer process.**

---

## Workflow

> USER GATE questions below are templates: ask them in the user's language, and stop until the user answers.
> **No answer is not a yes**: if a question tool returns "skipped", times out, or the session is non-interactive, treat
> it as NO — end the turn with the question and a summary instead of choosing for the user.

```
Task Progress:
- [ ] Step 1: Read-only probe
- [ ] USER GATE 1 (only if lima is not loaded)
- [ ] Step 2: Load the driver
- [ ] Step 3: Smoke test with gles_offscreen.py
- [ ] Step 4: Integrate (only if requested)
- [ ] USER GATE 2 (persistent loading)
- [ ] Step 5: Summary
```

### Step 1 — Read-only probe

Run `probe.sh` from this skill's directory — do not retype it inline (nested quotes break when the agent's local
shell is PowerShell or cmd):

```bash
bash probe.sh                              # on the board
scp probe.sh <target>:/tmp/ ; ssh <target> bash /tmp/probe.sh     # from a PC (same in bash, cmd, PowerShell)
```

Do not pipe the script through PowerShell (`Get-Content | ssh`): PowerShell prepends a BOM and has no `<` redirection.

Decide with this table:

| Check | Required | If not met |
|---|---|---|
| render node with driver `lima` | present | lima not loaded → look at the next rows |
| `CONFIG_DRM_LIMA` | `=y` / `=m`, or lima `.ko` available | not set → build lima + `gpu-sched` + `drm_shmem_helper` as external modules (skill `pynq-out-of-tree-kernel-module`) |
| device-tree node | `compatible` contains `arm,mali-400`; `interrupt-names` = `gp gpmmu pp0 ppmmu0 pp1 ppmmu1`; `clock-names` = `bus core`; `status` not `disabled` | missing / different names → lima cannot bind; stop and report (needs a device-tree change) |
| `lima_dri.so`, `libgbm.so.1` | present | install Mesa (`libgl1-mesa-dri`, `libgbm1`, `libegl-mesa0`) |
| PyOpenGL | importable | `pip install PyOpenGL` (3.1.5 tested) |

EARLY EXIT: if a `lima` render node already exists → go to Step 3.

### USER GATE 1 — Driver

Present the probe table. If the driver must be built or loaded, ask:
**"lima is not loaded. Build / load it now? Loading a kernel module can hang the board (power-cycle needed). The first load is temporary and is undone by a reboot."**

### Step 2 — Load the driver (temporary)

```bash
insmod gpu-sched.ko && insmod drm_shmem_helper.ko && insmod lima.ko     # this order
dmesg | grep -i lima | tail
```

VERIFY: `dmesg` lists `gp`, `pp0`, `pp1` (Mali-400 MP2), the L2 cache and `mod rate` (≈ 500 MHz on ZU5EG), and a
new render node whose driver is `lima` appears. Otherwise report the `dmesg` lines and stop.

### Step 3 — Smoke test

Copy `gles_offscreen.py` (this skill's directory) to a scratch directory on the board (e.g. `/tmp`) and run it:

```bash
python3 gles_offscreen.py            # 940x430
python3 gles_offscreen.py 320 240
```

VERIFY all three:
- `GL_RENDERER: Mali400` (anything else, e.g. `llvmpipe`, means the wrong node or no driver)
- `blank=False`
- `gles_test.png` shows a shaded surface with black axes — copy it back and look at it

Report the printed draw and readback times; compare with the reference table below.

### Step 4 — Integrate (only if the user asked for it)

Build on the `OffscreenGLES` class of `gles_offscreen.py`. Rules:

1. **Process split:** the renderer runs as a child process; exchange binary messages over stdin/stdout
   (request: size + data arrays; response: render time + `W*H*4` RGBA bytes). At most one request in flight; a newer
   request replaces one not yet sent.
2. **Context setup order:** set `PYOPENGL_PLATFORM=egl` before the first `import OpenGL`; open the lima node;
   `gbm_create_device(fd)` via ctypes; `eglGetPlatformDisplay(0x31D7 /*EGL_PLATFORM_GBM_KHR*/, gbm)`; config with
   `EGL_OPENGL_ES2_BIT` and `EGL_SURFACE_TYPE = 0`; `eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)`.
3. **Render target:** FBO with an RGBA texture (colour) and a `GL_DEPTH_COMPONENT16` renderbuffer; check
   `glCheckFramebufferStatus`.
4. **GLSL ES 1.00:** `#version 100`; fragment shaders need `precision mediump float;`.
   `glUniformMatrix4fv` must use `transpose=GL_FALSE` → upload `M.T` for a row-major NumPy matrix.
   Index buffers: `GL_UNSIGNED_SHORT` (≤ 65536 vertices per draw).
5. **Orientation:** multiply the projection by `diag(1, -1, 1, 1)` so `glReadPixels` returns the top row first
   (no CPU flip). With this flip the triangle winding is reversed — keep face culling off or swap the front face.
6. **One vertex buffer per draw call** within a frame.
7. **Watchdog:** render one warm-up frame at start; if 3 consecutive frames are a single colour (`is_blank()`), exit the
   renderer; the parent restarts it.
8. **Text:** draw labels in the GUI on the CPU; share the camera/projection function between GUI and renderer so the
   labels line up with the GPU-drawn axes.
9. **Fallback:** if no lima node exists, the program must still run with a 2-D view.

### USER GATE 2 — Persistent loading

Only after Step 3 passes, ask: **"Load lima automatically at boot?"** On yes:

```bash
cp gpu-sched.ko drm_shmem_helper.ko lima.ko /lib/modules/$(uname -r)/extra/ && depmod -a
echo lima > /etc/modules-load.d/lima.conf
# undo:
# rm /etc/modules-load.d/lima.conf /lib/modules/$(uname -r)/extra/{gpu-sched,drm_shmem_helper,lima}.ko && depmod -a
```

Tell the user: the modules match only this kernel (`uname -r`); after an image/kernel update they fail to load
(boot is unaffected) and must be rebuilt. Render-node numbers can change after this — another reason to search by driver.

### Step 5 — Summary

| Item | Result |
|---|---|
| Device / kernel | `<uname -r>`, `<gcc of kernel>` |
| lima | already loaded / built + loaded temporarily / persistent |
| Render node | `/dev/dri/renderDxxx -> lima` |
| `GL_RENDERER` | `Mali400` |
| Draw / readback at W×H | `<ms>` / `<ms>` |
| Files changed on the board | list, with undo commands |

Remove every file you copied to the board (`probe.sh`, `gles_offscreen.py`, PNGs), also when you stop at a USER GATE.

---

## Paths that do not work (tested on PYNQ-ZU, do not re-test)

| Path | Result |
|---|---|
| GLX clients in the PYNQ X desktop (armsoc DDX) | `llvmpipe` only, even with lima loaded |
| Xorg `modesetting` DDX instead of armsoc | segfault at start with the Xilinx DisplayPort driver `xlnx` (also with acceleration off) |
| Whole Qt app with `QT_QPA_PLATFORM=eglfs` on KMS | GPU is used, but widgets are still CPU-drawn and the full screen is uploaded every frame: CPU load rose from 27 % to 85 % |
| pyqtgraph.opengl / fixed-function desktop GL | not available through GBM/EGL (OpenGL ES 2.0 only) |

## Reference numbers

PYNQ-ZU (xczu5eg), PynqLinux (Ubuntu 22.04), kernel 6.6.10-xilinx-v2024.1, Mesa 22.0.1, PyOpenGL 3.1.5, `gles_offscreen.py`:

| Size | Geometry + draw | `glReadPixels` |
|---|---|---|
| 940 × 430 | ≈ 11 ms | ≈ 49 ms |
| 320 × 240 | ≈ 10 ms | ≈ 10 ms |

Readback grows roughly with the pixel count and dominates; budget it before choosing size and refresh rate.
In the source project a 52-subcarrier × 5-second surface with grid lines at 940 × 430 (≈ 60 ms per frame), refreshed
2.5 times per second, costs about 10 % of one A53 core.

## Files

| File | Purpose |
|---|---|
| `probe.sh` | Read-only probe: render nodes and their drivers, kernel config, loaded modules, device-tree node, Mesa / PyOpenGL |
| `gles_offscreen.py` | Minimal renderer class (`OffscreenGLES`), blank-frame check, smoke test |
| `prompts.md` | Example prompts |
