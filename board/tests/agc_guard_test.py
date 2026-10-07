"""Acceptance test of the sync-based AGC watchdog (jscc-rx running; reads SYNC_CNT only, sets the TX attenuation).
  1  TX att 4 dB (= 0 dB extra) for 180 s: watchdog resets must be 0
  2  6 x jump 4 -> 24 dB at rate 0: the last sync gap (> 0.2 s) must end within 2.5 s of the jump
  3  TX att 89.75 dB (no signal) for 30 s, then back to 4 dB: report resets, recovery within 2.5 s
    bash -lc 'source /etc/profile.d/pynq_venv.sh && python3 agc_guard_test.py [tests, e.g. 2 or 13]'
"""
import socket
import sys
import time
from pynq import MMIO
import jscc_udp as U

reg = MMIO(0x8002_0000, 0x1_0000)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
LOG = "rx_server.log"                       # run in the rx_server working directory


def attn(db, rate=0):
    s.sendto(U.ATTN + f" {db:.2f} {rate}".encode(), ("192.168.4.1", U.PORT_TX))


def resets():
    return sum("AGC guard: sync" in l for l in open(LOG, errors="replace"))


def record(dur):
    """SYNC_CNT at 20 Hz for dur s -> times of increments (relative to start)"""
    t0, last, inc = time.time(), reg.read(0x20), []
    while time.time() - t0 < dur:
        time.sleep(0.05)
        n = reg.read(0x20)
        if n != last:
            inc.append(time.time() - t0); last = n
    return inc


def recovery(inc, dur):
    """end of the last sync gap > 0.2 s (s after start; 0 = never lost), None = not recovered"""
    pts = [0.0] + inc
    if dur - pts[-1] > 0.2:
        return None
    ends = [b for a, b in zip(pts, pts[1:]) if b - a > 0.2]
    return round(ends[-1], 2) if ends else 0.0


TESTS = sys.argv[1] if len(sys.argv) > 1 else "123"
ok = True


def test1():
    global ok
    attn(4.0); time.sleep(3)
    r0 = resets()
    inc = record(180)
    r1 = resets()
    gaps = max(b - a for a, b in zip(inc, inc[1:])) if len(inc) > 1 else None
    t1 = r1 - r0 == 0
    ok &= t1
    print(f"[1] 180 s at 4 dB: {len(inc) / 180:.1f} sync/s, max gap {gaps:.2f} s, resets {r1 - r0} -> {'PASS' if t1 else 'FAIL'}",
          flush=True)


def test2():
    global ok
    rec = []
    for k in range(6):
        attn(4.0); time.sleep(4)
        r0 = resets()
        attn(24.0)
        inc = record(8)
        rv = recovery(inc, 8)
        rec.append(rv)
        print(f"[2] jump {k + 1}: recovered at {rv} s, resets {resets() - r0}", flush=True)
    t2 = all(r is not None and r <= 2.5 for r in rec)
    ok &= t2
    print(f"[2] -> {'PASS' if t2 else 'FAIL'}", flush=True)


def test3():
    global ok
    r0 = resets()
    attn(89.75); time.sleep(30)
    r1 = resets()
    attn(4.0)
    inc = record(8)
    rv = recovery(inc, 8)
    t3 = rv is not None and rv <= 2.5
    ok &= t3
    print(f"[3] 30 s no signal: resets {r1 - r0}; back to 4 dB: recovered at {rv} s, resets {resets() - r1} "
          f"-> {'PASS' if t3 else 'FAIL'}", flush=True)


for k in TESTS:
    (test1, test2, test3)[int(k) - 1]()
attn(4.0)
print("ALL PASS" if ok else "FAILED", flush=True)
