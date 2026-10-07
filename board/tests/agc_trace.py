"""Diagnostic (read only, jscc-rx and the GUI stopped): AD9361 CTRL_OUT (rx_ps_regs 0x3C: [7] gain lock, [6:0] gain
index with pointer 0x035 = 0x16) polled from the PS at ~1 us, SSCC vs DeepJSCC mode, to see how the fast-attack
AGC moves inside each PHY frame.

    bash -lc 'source /etc/profile.d/pynq_venv.sh && python3 agc_trace.py --att 14 --dur 0.3 --out meas/agc_trace'
-> <out>.npz: t_<mode> (s), v_<mode> (uint8 register value), sync_<mode> (SYNC_CNT samples, same times)
"""
import argparse
import socket
import time
import numpy as np
from pynq import MMIO
import jscc_udp as U

ap = argparse.ArgumentParser()
ap.add_argument("--att", type=float, default=14.0)
ap.add_argument("--top", type=float, default=32.0)
ap.add_argument("--att0", type=float, default=4.0)
ap.add_argument("--src", default="preset:div2k_0802")
ap.add_argument("--modes", default="sscc,jscc")
ap.add_argument("--dur", type=float, default=0.3, help="s of polling per mode")
ap.add_argument("--adc", type=int, default=0, help="instead: N raw ADC captures (dur s each, trig now) with CTRL_OUT "
                "polled during each capture (-> adc_<mode> (N, samples) dB envelopes per 8 samples, t0 of each capture)")
ap.add_argument("--wr", default="", help="AD9361 register writes before the run, e.g. 0x101=0x0E,... (lost at the "
                "next jscc-rx start: it re-initialises the AD9361)")
ap.add_argument("--out", default="meas/agc_trace")
args = ap.parse_args()

reg = MMIO(0x8002_0000, 0x1_0000)
rx = None
if args.adc:
    from pynq import allocate
    from jscc_rx import JsccRx, iq12
    rx = JsccRx(download=False)
for w in filter(None, args.wr.split(",")):
    a, v = (int(x, 0) for x in w.split("="))
    if rx is None:
        from jscc_rx import JsccRx
        rx = JsccRx(download=False)
    old = rx.rf.rd(a); rx.rf.wr(a, v)
    print(f"AD9361 0x{a:03X}: 0x{old:02X} -> 0x{v:02X} (reads 0x{rx.rf.rd(a):02X})", flush=True)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1.0)
TX = ("192.168.4.1", U.PORT_TX)


def tx(cmd):
    s.sendto(cmd, TX)
    t_end = time.time() + 1.0
    while time.time() < t_end:
        try:
            d = s.recv(65536)
        except socket.timeout:
            break
        if d.startswith(U.ATTS):
            return d.decode()
    return None


def poll(dur):
    n = int(dur * 2e6)
    t = np.zeros(n); v = np.zeros(n, np.uint8); sc = np.zeros(n, np.uint32)
    pc, rd = time.perf_counter, reg.read
    t0 = pc(); i = 0
    while i < n:
        v[i] = rd(0x3C); sc[i] = rd(0x20); t[i] = pc() - t0
        if t[i] > dur:
            break
        i += 1
    return t[:i], v[:i], sc[:i]


def adc_poll(dur):
    """one raw ADC capture of dur s (started now) with CTRL_OUT polled meanwhile; times relative to the capture start"""
    n = int(dur * 20e6) // 8 * 8
    buf = allocate(shape=(n,), dtype=np.uint32)
    try:
        rx.cap_dma.recvchannel.transfer(buf)
        rx.wr("CAP_LEN", n)
        rx.wr("CAP_CTRL", 1)                                  # trig now (the ring delays the data by 2048 samples)
        t, v, sc = poll(dur + 0.002)                          # poll() times start right after the trigger
        if not rx._wait(rx.cap_dma.recvchannel, 2.0):
            rx._dma_reset(rx.cap_dma)
            raise TimeoutError("capture did not complete")
        buf.invalidate()
        x = iq12(np.array(buf))
    finally:
        buf.freebuffer()
    p = (x.real ** 2 + x.imag ** 2).reshape(-1, 8).mean(1) / 2048.0 ** 2
    return t, v, sc, (10 * np.log10(np.maximum(p, 1e-12))).astype(np.float32)


orig = tx(U.MODE + b" sscc")                         # any command answers with the state (mode set below anyway)
print("TX at start:", orig, flush=True)
out = {}
try:
    tx(U.SRC + b" " + args.src.encode())
    for mode in args.modes.split(","):
        tx(U.MODE + b" " + mode.encode())
        tx(U.ATTN + b" %.2f" % (args.att0 + args.top)); time.sleep((args.top + 2) / 10 + 4)
        print(tx(U.ATTN + b" %.2f 0" % (args.att0 + args.att)), flush=True); time.sleep(4)
        if args.adc:
            for k in range(args.adc):
                t, v, sc, env = adc_poll(args.dur)
                out[f"t_{mode}_{k}"], out[f"v_{mode}_{k}"], out[f"sync_{mode}_{k}"], out[f"env_{mode}_{k}"] = t, v, sc, env
                time.sleep(0.05)
            print(f"{mode}: {args.adc} captures with CTRL_OUT, last {len(t)} polls", flush=True)
            continue
        t, v, sc = poll(args.dur)
        out[f"t_{mode}"], out[f"v_{mode}"], out[f"sync_{mode}"] = t, v, sc
        print(f"{mode}: {len(t)} samples in {t[-1]:.3f} s ({t[-1] / len(t) * 1e6:.2f} us each)", flush=True)
finally:
    f = orig.split() if orig else []
    if len(f) >= 5:
        tx(U.SRC + b" " + f[4].encode()); tx(U.ATTN + b" " + f[2].encode() + b" 0"); tx(U.MODE + b" " + f[3].encode())
    print("TX restored:", tx(U.HELLO), flush=True)
np.savez_compressed(args.out + ".npz", **out)
print("saved", args.out + ".npz", flush=True)
