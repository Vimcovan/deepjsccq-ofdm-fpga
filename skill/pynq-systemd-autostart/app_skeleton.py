"""Skeleton of a PYNQ program meant to run under systemd (see pynq-app.service).

- loads the overlay and checks that the hardware really works; reloads a few times if not
- turns SIGTERM (systemctl stop / restart / shutdown) into a normal exit, so the `finally` clean-up runs
- flushes every log line (systemd appends stdout to a file)
Adapt the three marked places.
"""
import signal
import sys
import time

from pynq import Overlay

BITFILE = "<design>.bit"                  # (1) your bitstream (.hwh with the same base name next to it)
LOAD_TRIES = 5


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def self_test(ol):
    """(2) Return True if the design works after loading: e.g. a version/ID register reads the expected value,
    a free-running counter advances, a DMA loopback returns the pattern. Keep it short (< a few seconds)."""
    return True


def load_overlay():
    for attempt in range(1, LOAD_TRIES + 1):
        ol = Overlay(BITFILE)
        ok = self_test(ol)
        log(f"overlay load {attempt}/{LOAD_TRIES}: self-test {'ok' if ok else 'FAILED'}")
        if ok:
            return ol
        time.sleep(1)
    log("overlay never passed the self-test, exiting (systemd restarts the service)")
    sys.exit(1)


# Python's default SIGTERM action ends the process at once: `finally` blocks and atexit handlers do NOT run.
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

ol = load_overlay()
log("running")
try:
    while True:                           # (3) the program's main loop
        time.sleep(1)
finally:
    # leave the hardware in a state the next process can use: stop the PL datapath, reset DMA channels that may
    # still wait for data (see skill pynq-dma-stale-transfer), close devices
    log("stopped, hardware released")
