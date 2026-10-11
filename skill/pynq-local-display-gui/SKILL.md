---
name: pynq-local-display-gui
description: Run a full-screen Python / PyQt5 GUI on the display attached to a PYNQ board (DisplayPort / HDMI, optionally a USB touch screen) for a stand-alone demo — check the display stack, verify the layout off-screen on the board before anyone looks at the screen, keep the GUI within the Cortex-A CPU budget next to the real workload, set the display mode, and make touch work (including press-and-hold / drag when the kernel lacks hid-multitouch). Use when the user wants to show results on a monitor or touch screen connected to the board, says the GUI is slow / laggy on the board, text does not fit the small screen, the screen stays black, or touch only produces single taps.
argument-hint: "[GUI script] [ssh-target]"
---

# Full-screen PyQt GUI on the PYNQ Board's Own Display

## Purpose

Bring a GUI that works on a PC to the monitor or touch screen attached to the board, without a PC in the loop,
and without starving the program that does the real work.

**Expected outcome:** a display/touch probe report, off-screen screenshots of every page at the real screen size
with a list of text overflows, CPU measurements of the GUI on the board, and the GUI running full screen
(as a service, see skill `pynq-systemd-autostart`).

**Prerequisites:**
- Board with a display output (PYNQ-ZU / ZCU104 DisplayPort, or an HDMI-out overlay) and the PYNQ X server
- PyQt5 on the board (if missing: apt `python3-pyqt5`; offline boards: skill `pynq-offline-packages`, if installed)
- The GUI's code; the screen's resolution

---

## When to Use

- "Show the camera image / results on the screen attached to the board"
- GUI is slow or makes the main program miss deadlines on the board
- Labels cut off on a small screen; nobody can look at the screen right now (remote agent)
- Touch screen: taps work but holding a button or dragging a slider does not

## When NOT to Use

- GUI runs on a PC and only receives data from the board → normal desktop development
- Video output entirely in PL (HDMI/DP pipeline from an overlay, no X) → not a Qt task
- 3-D OpenGL drawing → also use skill `mali400-offscreen-gles` (X only offers software OpenGL)

---

## DO's

- **Track every file you copy to the board and delete it whenever you stop** — before the summary, at a USER GATE, and
  before any clarifying question (scripts, copies of the user's program, screenshots, error logs in `/tmp`)
- Stay inside the workspace and the board paths the user named; do not search other directories on the PC for the user's files — ask
- Probe first (`display_probe.sh`): connector, X server, mode, input devices and their drivers, PyQt5 in the venv
- **Check the layout off-screen on the board** (`offscreen_shots.py`) before asking a person to look at the screen;
  read the screenshots yourself
- Measure the GUI's CPU use **on the board, with the real workload running**, per page
- Update only the visible page; throttle plots to what the eye needs (2–5 Hz for curves, image at source rate)
- Draw dense data (scatter plots, heat maps) into one `QImage` instead of thousands of plot items
- Keep network / hardware I/O out of the GUI process (separate process or the existing server) — the GIL blocks painting
- Start the GUI as a systemd service ordered after `pynq-x11.service`

## DON'Ts

- **Never kill processes by name** on the PC or the board (`Stop-Process -Name ssh`, `Get-Process ssh | Stop-Process`, `pkill ssh`, `killall python3`) — other sessions use them; stop only a process you started, by its exact PID
- **Copy commands name the remote side explicitly**: `scp <local file> <target>:<remote dir>/` and `scp <target>:<remote file> <local dir>/`; never pass a local credential (the `-i` key, anything under `~/.ssh`) as a source or destination, and never write into `~/.ssh`
- **Never judge layout from a PC screenshot** — fonts, Qt version and DPI differ from the board
- **Never move the whole GUI to `QT_QPA_PLATFORM=eglfs` hoping for GPU speed** — widgets stay CPU-drawn and the full screen is uploaded every frame (CPU rose from 27 % to 85 % on the reference board)
- **Never edit the user's GUI code, change the display mode, X configuration or kernel modules without the user's go-ahead** (USER GATE 1 / 2)
- Do not use `pyqtgraph.opengl` (3-D) on the board — software OpenGL, unusable frame rates
- Do not chase touch problems in Qt before looking at the raw evdev events (Step 5)

> **Measured, not guessed:** the PC GUI copied to the board unchanged used 100 % of one A53 core and redrew its plot
> page 2.4 times per second with 1–3 s stalls. After the changes in Step 4 the image page used 27 % (30 frames/s)
> and the plot page 78 %, while the receiving program kept its 30 frames/s.

---

## Workflow

> USER GATE questions below are templates: ask them in the user's language, and stop until the user answers.
> **No answer is not a yes**: if a question tool returns "skipped", times out, or the session is non-interactive, treat
> it as NO — end the turn with the question and a summary instead of choosing for the user.

```
Task Progress:
- [ ] Step 1: Probe display, input, Python stack
- [ ] Step 2: Off-screen screenshots + overflow check
- [ ] Step 3: CPU budget on the board
- [ ] USER GATE 1: report findings, ask before changing the GUI code
- [ ] Step 4: Fix layout / performance
- [ ] USER GATE 2: show on the real screen
- [ ] Step 5: Touch
- [ ] Step 6: Full screen as a service
- [ ] Step 7: Clean up + summary
```

### Step 1 — Probe

```bash
scp display_probe.sh <target>:/tmp/ ; ssh <target> bash /tmp/display_probe.sh
```

| Check | Expected | If not |
|---|---|---|
| connector (`card*-DP-1` …) | `connected` | cable / adapter / monitor power; DP→HDMI adapters may need a powered model |
| `pynq-x11.service` | `active`, `Xorg` running, `X reachable on :0` | start the service; GUI processes need `DISPLAY=:0 XAUTHORITY=/root/.Xauthority` |
| current mode (`*` in xrandr) | screen's native resolution | Step 6, mode setting |
| screen saver / DPMS | `timeout: 0`, `DPMS is Disabled` | `xset s off -dpms` before the GUI starts |
| touch device | an `eventN` handler; HID driver `hid-multitouch` | `hid-generic` + `CONFIG_HID_MULTITOUCH is not set` → taps only, Step 5 |
| PyQt5 / pyqtgraph | versions printed | install (skill `pynq-offline-packages`) |

### Step 2 — Off-screen screenshots

Copy the GUI and `offscreen_shots.py` into one scratch directory on the board (e.g. `/tmp/gui_check/`) and run there:

```bash
source /etc/profile.d/pynq_venv.sh
cd /tmp/gui_check && python3 offscreen_shots.py <module> <WindowClass> <W> <H> /tmp/gui_check/shots [-- <GUI args>]
```

It renders at W×H with `QT_QPA_PLATFORM=offscreen`, saves `window.png` and one PNG per tab of every `QTabWidget`,
and prints `OVERFLOW` for each visible label / button whose text is wider than the widget. Copy the PNGs back and
look at them. For states that are hard to trigger on hardware (error messages, long names, empty data), set them in
a copy of the script before `shot()` and screenshot them too.

### Step 3 — CPU budget

Run the real workload, then the GUI on the board (off-screen is fine for a first number), and measure per page:

```bash
top -b -d 5 -n 3 -p $(pgrep -d, -f '<gui script>') | grep -A3 PID
```

Also confirm the main program still meets its rate (its own log or counters). Budget: the GUI should leave the
workload its cores; on a 4-core A53 aim for well below one core for the GUI.

### USER GATE 1 — Findings

Report the screenshots, overflows and CPU numbers. If the user only asked for a check, stop here and ask:
**"Fix these N problems in `<file>`?"** Do not edit the user's code before the answer.

### Step 4 — Fixes (apply the ones the measurements call for)

| Symptom | Fix |
|---|---|
| Hidden pages still repaint | update only the current tab (`currentChanged` → start/stop that page's timer) |
| Curves redrawn on every sample | collect data, redraw at 2–5 Hz |
| Scatter / constellation with ~1000 points per plot | accumulate a 2-D histogram, show it as one `QImage` (e.g. 200×200) with the grid drawn into it |
| `pyqtgraph.ImageItem` for a live image | own `QWidget.paintEvent` drawing a `QImage` with integer scaling (≈ 15 → 7 ms per frame on A53) |
| Receiving data in a GUI thread | move it into a child process; pass only complete messages to the GUI |
| Antialiasing on large plots | off on the board |
| Text overflow | shorter text, smaller font, or wrap; re-run Step 2 |

### USER GATE 2 — Real screen

Ask: **"Show the GUI on the screen now? This stops anything currently drawn there<, and sets the display mode to W×H>."**

### Step 5 — Touch

1. Device stable? `dmesg | grep -iE 'usb|hid' | tail` — repeated disconnects or `error -32` / `-71` are power or cable problems
   (powered hub, separate supply for the screen); fix that first.
2. Raw events while a finger is held 3 s: `python3 evdev_touch.py <name part> <W> <H>` prints the axis range and
   `down` / `move` / `up`.
   - Continuous `move` while held, but the GUI only sees taps → `hid-generic` clears `BTN_TOUCH` in every report.
     Either use `EvdevTouch` from `evdev_touch.py` in the GUI for hold / drag (taps keep working through X), or
     build `hid-multitouch` as a module (skill `pynq-out-of-tree-kernel-module`).
   - No events while held → hardware / connection, not software.
3. In Qt, emit a signal from the `EvdevTouch` callbacks and handle it in the GUI thread
   (`QApplication.widgetAt(x, y)` to find the widget).

### Step 6 — Full screen as a service

- `showFullScreen()` on the board (keep a windowed mode for the PC).
- Mode: `xrandr --output <OUT> --mode <W>x<H>`; if the mode is not listed, `cvt W H 60` → `xrandr --newmode` + `--addmode`.
  Some DP→HDMI adapters stay dark after a direct mode change: `xrandr --output <OUT> --off; sleep 2; xrandr --output <OUT> --mode ...`.
  If the adapter reports a default EDID (wrong size / resolution), set the mode explicitly.
- Service: unit from skill `pynq-systemd-autostart` with `After=pynq-x11.service`, `DISPLAY`, `XAUTHORITY`, an
  `ExecStartPre` that waits for `xset -q`, a mode / `xset s off -dpms` script as another `ExecStartPre`, and `Restart=always`.

### Step 7 — Clean up and summarize

Copy the screenshots back, then `rm -rf /tmp/gui_check /tmp/display_probe.sh` on the board.


| Item | Result |
|---|---|
| Display | connector, mode, X service |
| Layout | pages captured, overflows found / fixed |
| CPU | GUI per page (% of one core), workload rate before / after |
| Touch | driver, taps / hold / drag status, method |
| Service | unit name, start order |
| Files changed on the board | list + undo |

---

## Reference

PYNQ-ZU, PynqLinux 3.0: X from `pynq-x11.service` (`startx` as root, fluxbox, `armsoc` DDX, display `:0`,
`XAUTHORITY=/root/.Xauthority`), DisplayPort `card0-DP-1`; PyQt5 5.15.6 / Qt 5.15.3 / pyqtgraph 0.12.4 from apt;
kernel without `CONFIG_HID_MULTITOUCH`. 1024×600 USB touch screen (WCH `USB2IIC_CTP`, ABS range 0–32767,
≈ 90 reports/s while held) behind a DP→HDMI adapter. `offscreen_shots.py` on a two-tab window: 1.8 s.

## Files

| File | Purpose |
|---|---|
| `display_probe.sh` | Read-only probe: connectors, X, mode, screen saver, input devices + HID drivers, PyQt5 |
| `offscreen_shots.py` | Off-screen screenshots of every tab at W×H + text-overflow report |
| `evdev_touch.py` | Finger down / move / up from raw evdev (axis range read from the device) |
