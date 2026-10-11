---
name: pynq-systemd-autostart
description: Make a PYNQ program (Python + overlay, optionally a GUI on the board's display) start automatically at power-on and run without Jupyter, a PC or an ssh session, using a systemd service — with the PYNQ-specific ordering (bootpy.service loads base.bit and would overwrite an overlay loaded earlier), the PYNQ venv, waiting for X / USB devices, overlay self-test with reload, clean SIGTERM shutdown, logging, restart policy, and a real power-cycle test. Use when the user wants a demo that runs on power-up, asks to run a PYNQ script "as a service", "at boot", "without the notebook", or reports that their overlay works when started by hand but not after reboot.
argument-hint: "[program path] [ssh-target]"
---

# PYNQ Program as a systemd Service (autostart)

## Purpose

Turn a program that works when started by hand into a service that comes up by itself after power-on, survives
crashes, stops cleanly, and leaves logs.

**Expected outcome:** a unit file adapted from `pynq-app.service`, the program's start-up / shut-down made
service-safe (`app_skeleton.py` patterns), and — after the user agrees — the service installed, enabled and verified
by an actual power cycle.

**Prerequisites:**
- The program already works when started by hand as root on the board
- Root shell on the board; PYNQ image with systemd (PYNQ 2.x / 3.x)

---

## When to Use

- "Start my overlay / program at boot", "run without Jupyter", "demo must work with just the power switch"
- The program works by hand but not after reboot (overlay overwritten, module not found, no display)
- Several programs must start in order (e.g. a data server, then a GUI)

## When NOT to Use

- One-off experiments → run by hand
- Jupyter notebooks → convert the notebook to a script first; do not autostart notebooks

---

## DO's

- **Track every file you copy to the board and delete it whenever you stop** — before the summary, at a USER GATE, and
  before any clarifying question (scripts, copies of the user's program, screenshots, error logs in `/tmp`)
- Stay inside the workspace and the board paths the user named; do not search other directories on the PC for the user's files — ask
- Order the unit **after `bootpy.service`** (PYNQ runs `/boot/boot.py` there, and the stock `boot.py` loads `base.bit`)
- Start Python through a **login shell that sources the PYNQ venv**: `bash -lc 'source /etc/profile.d/pynq_venv.sh && exec python3 ...'`
- In the program: **SIGTERM handler → `sys.exit(0)`**, release the hardware in `finally`
- After loading the overlay, run a **self-test** and reload a few times if it fails
- Wait for devices / X in `ExecStartPre` loops with a timeout instead of `sleep N`
- Log with `flush=True` / `python3 -u`; send stdout to a file with `StandardOutput=append:`
- Before debugging by hand: `systemctl stop <service>` — otherwise two processes fight over the PL

## DON'Ts

- **Never kill processes by name** on the PC or the board (`Stop-Process -Name ssh`, `Get-Process ssh | Stop-Process`, `pkill ssh`, `killall python3`) — other sessions use them; stop only a process you started, by its exact PID
- **Copy commands name the remote side explicitly**: `scp <local file> <target>:<remote dir>/` and `scp <target>:<remote file> <local dir>/`; never pass a local credential (the `-i` key, anything under `~/.ssh`) as a source or destination, and never write into `~/.ssh`
- **Never load an overlay before `bootpy.service` has finished** — `base.bit` overwrites it
- **Never use `/usr/bin/python3` directly in `ExecStart`** — on PYNQ 3.x `pynq` is only installed in the venv (`ModuleNotFoundError: No module named 'pynq'`)
- **Never install, enable or reboot without the user's go-ahead** (USER GATE 1 / 2)
- Do not start long-running board programs from ssh with `&` alone — without `</dev/null >log 2>&1` ssh waits for them; with a service this question disappears
- Do not kill programs with `pkill -f name` — it can match the shell running the command; use `systemctl stop`, an exact PID, or an anchored pattern `pkill -f '^python3 app.py'`
- Do not autostart a Jupyter notebook that loads an overlay as well — the last loader wins

> **Why the SIGTERM handler:** on the reference board, a Python process stopped with `kill -TERM` exited with status
> 143 and its `finally` block did **not** run; with `signal.signal(SIGTERM, lambda *_: sys.exit(0))` it exited with 0
> and the clean-up ran. Without it, `systemctl stop` leaves DMA transfers pending and the next process hangs.
> Releasing an AXI DMA receive channel: `dma.mmio.write(0x30, 4)` (S2MM soft reset), wait until bit 2 of
> `dma.mmio.read(0x30)` clears, then `dma.recvchannel.start()` — `recvchannel.stop()` does not cancel a pending transfer
> (details: skill `pynq-dma-stale-transfer`, if installed).

---

## Workflow

> USER GATE questions below are templates: ask them in the user's language, and stop until the user answers.
> **No answer is not a yes**: if a question tool returns "skipped", times out, or the session is non-interactive, treat
> it as NO — end the turn with the question and a summary instead of choosing for the user.

```
Task Progress:
- [ ] Step 1: Inspect the program and the board
- [ ] Step 2: Make the program service-safe
- [ ] Step 3: Write the unit file
- [ ] USER GATE 1: install + start
- [ ] Step 4: Install, start, verify
- [ ] USER GATE 2: enable + power-cycle test
- [ ] Step 5: Boot test
- [ ] Step 6: Clean up + summary
```

### Step 1 — Inspect

```bash
systemctl cat bootpy.service; grep -v '^#' /boot/boot.py | grep -v '^$'   # what runs at boot (base.bit?)
cat /etc/profile.d/pynq_venv.sh                                            # venv path
systemctl list-units --type=service --no-pager | grep -iE 'pynq|jupyter|x11'
systemctl list-unit-files --no-pager | grep -E '\.service +enabled' | grep -viE 'systemd|getty|ssh'  # other autostarts
```

Read the program: which overlay it loads, which devices it opens (`/dev/video*`, `/dev/tty*`, display), what it
needs at exit (DMA, files, PL state), how it is started by hand (arguments, working directory, user).

### Step 2 — Program changes (show the diff)

If Step 1 finds blockers (program / bitstream not on the board yet, another service owns the PL), still do Steps 2–3
on the local copy and present the result together with the blocking questions at USER GATE 1 — the user then has
something to review while deciding.

From `app_skeleton.py`:
1. `signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))` before the main loop; hardware release in `finally`.
2. Overlay load + self-test + reload loop (a register with a known value, a counter that advances, a loopback).
   Exit with non-zero status if it never passes → systemd restarts the service (`Restart=on-failure`).
3. `print(..., flush=True)` (or `python3 -u`) so the log is complete when the process dies.
4. Paths relative to the program directory (`WorkingDirectory`), arguments from `EnvironmentFile`.

### Step 3 — Unit file

Fill in `pynq-app.service`. Decide per program:

| Need | Unit setting |
|---|---|
| Overlay | `After=bootpy.service` (always on PYNQ) |
| Kernel modules loaded at boot (`/etc/modules-load.d`) | `After=systemd-modules-load.service` |
| USB camera / serial device | `ExecStartPre` wait loop for the `/dev` node |
| GUI on the board's display | `After=`/`Wants=pynq-x11.service`, `Environment=DISPLAY=:0 XAUTHORITY=/root/.Xauthority`, `ExecStartPre` wait for `xset -q` |
| Must always be on screen | `Restart=always` (closing the window restarts it — tell the user) |
| Server that may crash | `Restart=on-failure`, `RestartSec=10` |
| Program B needs program A | in B: `After=a.service` + `Wants=a.service` |
| Tunable arguments | `EnvironmentFile=-<dir>/app.env` with `APP_ARGS=...` |

Check the file: `systemd-analyze verify <file>` (prints nothing when the syntax is fine).

### USER GATE 1 — Install and start

Show the unit file and the program diff, then ask:
**"Install `<name>.service` into /etc/systemd/system and start it now (not yet at boot)? Any program currently using the PL must be stopped first."**

### Step 4 — Install, start, verify

```bash
cp <name>.service /etc/systemd/system/ && systemctl daemon-reload
systemctl start <name>; sleep 10; systemctl status <name> --no-pager | head -15
tail -n 30 <program dir>/<program>.log
systemctl stop <name>; tail -n 5 <program dir>/<program>.log      # clean-up message must appear
systemctl start <name>                                            # second start must work too
```

VERIFY: `active (running)`, self-test passed on the first load, the stop wrote the clean-up line, and the second
start works (a failing second start usually means hardware left in a bad state by the first stop).

### USER GATE 2 — Enable at boot

Ask: **"Enable at boot and test with a real power cycle? I need you to switch the board off and on (a software `reboot` can hide problems that only appear from a cold start, e.g. USB devices that do not enumerate)."**

### Step 5 — Boot test

```bash
systemctl enable <name>
# user power-cycles the board, then:
systemd-analyze blame | grep -E 'bootpy|<name>'
journalctl -b -u bootpy -u <name> --no-pager | tail -20
tail -n 20 <program dir>/<program>.log
```

VERIFY: `<name>` started after `bootpy` finished, self-test ok, program running. Reference: on PYNQ-ZU `bootpy.service`
takes about 37 s (it loads `base.bit` and blinks the LEDs), so the overlay is loaded roughly 40–70 s after power-on.

### Step 6 — Clean up and summarize

Delete files you copied to `/tmp` for checks (e.g. `systemd-analyze verify` copies), also when you stop at a USER GATE.


| Item | Result |
|---|---|
| Unit | path, `After=` / `Wants=`, restart policy |
| Program changes | SIGTERM handler, self-test, logging |
| Start / stop / start by hand | ok / problems |
| Cold boot | time from power-on to running, number of overlay loads |
| Logs | file path, `journalctl -u <name>` |
| Control | `systemctl stop|start|restart <name>`; `systemctl disable <name>` to remove from boot; uninstall: `systemctl disable --now <name> && rm /etc/systemd/system/<name>.service && systemctl daemon-reload` |

---

## Reference

PYNQ-ZU, PynqLinux 3.0 (Ubuntu 22.04), pynq 3.1.1: `pynq` importable only in `/usr/local/share/pynq-venv`
(system `python3` → `ModuleNotFoundError`); the login shell also sources `/etc/profile.d/xrt_setup.sh`
(`XILINX_XRT=/usr`). `bootpy.service` (Type=oneshot, WantedBy=basic.target) runs `/boot/boot.py`, which by default
loads `base.bit`; it took 37 s. The X server is `pynq-x11.service` (`startx` as root, display `:0`). Three services
built this way (camera sender, receiver, full-screen GUI) came up without any manual step after a cold power cycle of both boards, about 1 minute after power-on.

## Files

| File | Purpose |
|---|---|
| `pynq-app.service` | Unit template with the PYNQ ordering, venv start, device / X wait, logging, restart |
| `app_skeleton.py` | Overlay load + self-test + reload, SIGTERM → clean exit, flushed logging |
