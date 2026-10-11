---
name: pynq-dma-stale-transfer
description: Fix PYNQ programs whose AXI DMA receive (S2MM) transfers hang — after a timeout, after the process was killed or stopped by systemd, or when the PL waits for a trigger / frame that never comes — so that the next transfer or the next process never completes or reads nothing. Gives the DMACR soft-reset recipe that pynq's `stop()` does not do, and where to put it. Use when the user reports `dma.recvchannel.wait()` hanging, a DMA that "works once", a second run that gets no data, or asks how to add timeouts / clean shutdown to PYNQ DMA code.
argument-hint: "[program path]"
---

# PYNQ AXI DMA: Clearing a Pending Receive Transfer

## Purpose

Make AXI DMA receive code robust against transfers that never finish: detect them with a timeout, clear them with a
soft reset, and never leave one behind when the process exits.

**Expected outcome:** the user's DMA code changed (timeout + reset helper + reset at exit), and a test showing that a
stopped / restarted program, or a transfer after a timeout, receives data again.

**Prerequisites:**
- PYNQ (2.x / 3.x) with `pynq.lib.dma.DMA` (AXI DMA IP in simple, non-scatter-gather mode)
- The program's source

---

## When to Use

- `recvchannel.wait()` blocks forever, or a polling loop on `recvchannel.idle` never ends
- The first run works; after Ctrl-C / `kill` / `systemctl stop` / a timeout the next transfer hangs or returns old data
- S2MM transfers where the PL may legitimately send nothing (trigger, frame sync, radio link down)

## When NOT to Use

- MM2S (send) only, and the PL always accepts data → a hang there is a PL back-pressure problem
- Scatter-gather mode → not covered here (descriptor rings need their own handling)
- The PL never produces TLAST → fix the PL; a reset only hides it

---

## DO's

- **Track every file you copy to the board and delete it whenever you stop** — before the summary, at a USER GATE, and
  before any clarifying question (scripts, copies of the user's program, screenshots, error logs in `/tmp`)
- Stay inside the workspace and the board paths the user named; do not search other directories on the PC for the user's files — ask
- Wait with a timeout: poll `recvchannel.idle` (or `wait_async` with `asyncio.wait_for`) instead of a bare `wait()`
- On timeout: **soft reset** (S2MM DMACR offset `0x30`, bit 2), then `recvchannel.start()`, then retry or report
- Reset every receive DMA when the process exits (`finally` + a SIGTERM handler that calls `sys.exit(0)`)
- **Also reset every receive DMA once at start-up**, right after loading the overlay: a previous process killed with
  SIGKILL, a crash or a power-off of the source cannot run its `finally`
- Hold the DMA lock while resetting at exit, so no other thread submits a transfer afterwards
- Keep a buffer alive until its transfer finished or the channel was reset

## DON'Ts

- **Never reboot or power-cycle the board yourself** — ask the user; a reboot interrupts whatever else runs on it
- **Never try passwords or default credentials** (ssh, Jupyter, web UIs) — if access fails, stop and report
- **Never kill processes by name** on the PC or the board (`Stop-Process -Name ssh`, `Get-Process ssh | Stop-Process`, `pkill ssh`, `killall python3`) — other sessions use them; stop only a process you started, by its exact PID
- **Copy commands name the remote side explicitly**: `scp <local file> <target>:<remote dir>/` and `scp <target>:<remote file> <local dir>/`; never pass a local credential (the `-i` key, anything under `~/.ssh`) as a source or destination, and never write into `~/.ssh`
- **Never rely on `recvchannel.stop()`** to cancel a pending S2MM transfer — despite its docstring ("aborts the current
  transfer"), pynq 3.1's `stop()` only writes 0 to DMACR and then loops until the halted flag is set, which does not
  happen while the channel still waits for data: it can block forever, and the transfer stays programmed
- **Never free (`freebuffer()`, let go out of scope) a buffer right after a timeout** — the pending transfer can
  still write into it later
- Do not reset a DMA whose MM2S side is busy in another thread without restarting that side too — the reset
  (`DMACR` bit 2) resets both directions of the same AXI DMA instance

> **Observed failure:** a receiver service left an ADC capture transfer waiting for the next frame when it was stopped
> with `systemctl stop`; the transmitter was off, so the frame never came. Every later capture process hung on its first
> transfer until the DMA was soft-reset. The same program's image DMA had been fixed earlier for timeouts; the capture
> DMA had been missed — **apply the reset to every receive channel**.

---

## Workflow

> USER GATE questions below are templates: ask them in the user's language, and stop until the user answers.
> **No answer is not a yes**: if a question tool returns "skipped", times out, or the session is non-interactive, treat
> it as NO — end the turn with the question and a summary instead of choosing for the user.
> **Explicit, low-risk requests need no GATE**: if the user already asked for exactly this action and it is easy to
> undo and changes nothing system-wide (copy files into a scratch directory, install a pure-Python package for the
> user's program, apply the fix the user asked for to the user's own file), do it and report what changed and how
> to undo it. Keep the GATE even after an explicit request for: loading kernel modules, installing / enabling /
> stopping / restarting services, rebooting, changing system configuration or system packages, anything that can
> take down the running application or the display, and editing code when the user only asked for a check.

```
Task Progress:
- [ ] Step 1: Find every receive DMA and how it waits
- [ ] Step 2: Add reset helper + timeout handling
- [ ] Step 3: Reset at start-up and at exit
- [ ] Step 4: Test the failure cases
- [ ] Step 5: Summary
```

### Step 1 — Inventory

Search the code for `recvchannel.transfer`, `recvchannel.wait`, `.idle`, `allocate(`, `freebuffer`. For each DMA:
which thread starts transfers, whether the PL may send nothing, how long a transfer normally takes, whether the
MM2S side of the same DMA is used.

### Step 2 — Reset helper and timeout

```python
import time

def dma_reset(dma, timeout=0.1):
    """AXI DMA soft reset (S2MM DMACR = 0x30, bit 2) and restart: drops a pending receive transfer."""
    dma.mmio.write(0x30, 0x4)
    t0 = time.time()
    while dma.mmio.read(0x30) & 0x4 and time.time() - t0 < timeout:   # bit clears when the reset is done
        pass
    dma.recvchannel.start()

def recv(dma, buf, timeout):
    """True if the transfer completed; on timeout the channel is reset and False returned."""
    dma.recvchannel.transfer(buf)
    t0 = time.time()
    while not dma.recvchannel.idle:
        if time.time() - t0 > timeout:
            dma_reset(dma)
            return False
        time.sleep(0.0005)
    return True
```

Timeout: a few times the normal transfer time (frame period × 2–3 for frame-triggered data).
If the program also sends on the same DMA (`sendchannel`), restart it after the reset as well (`dma.sendchannel.start()`).

### Step 3 — Reset at start-up and at exit

```python
import signal, sys
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))     # systemctl stop / kill: run the finally block
for d in (ol.dma_a, ol.dma_b):     # start-up: clear what a killed predecessor left behind
    dma_reset(d)
try:
    main_loop()
finally:
    dma_lock.acquire(timeout=3)        # kept: no thread starts another transfer after the reset
    for d in (ol.dma_a, ol.dma_b):     # every DMA with a receive channel
        dma_reset(d)
```

### Step 4 — Test

Show the user the diff, then test on the board (needs the overlay; stop any service using it first):

1. Make the PL send nothing (disable the source / trigger), start a receive, let it time out → next transfer with the
   source enabled must complete.
2. Start a receive with the source disabled, stop the program (`kill -TERM` / `systemctl stop`), start a new process
   → its first transfer must complete.
3. Start a receive with the source disabled, `kill -9` the program, start a new process → its first transfer must
   complete (start-up reset).
4. Normal operation for a few minutes: no timeouts, no rate drop.

Without the board: mock `mmio` / `recvchannel` and check the call order (transfer → timeout → reset → start; exit → reset → `freebuffer`).

### Step 5 — Summary

| DMA | Direction | Timeout | Reset on timeout | Reset at start / exit | Tests 1–4 |
|---|---|---|---|---|---|

---

## Reference

PYNQ-ZU, pynq 3.1.1, AXI DMA (simple mode): register offsets MM2S DMACR `0x00`, S2MM DMACR `0x30`, bit 2 = reset
(self-clearing), bit 0 = run/stop. Two receive DMAs (image data and ADC capture) with this recipe: restarts of the
service and timeouts no longer leave the next process hanging.

## Files

None — the helper above is the whole implementation.
