"""Diagnostic (read only, jscc-rx and the GUI stopped: uses the capture DMA): raw ADC envelopes of whole PHY frames,
SSCC vs DeepJSCC mode, to look for receive-level steps after the preamble (AGC gain change between LTF and data ->
wrong channel estimate) and at the gaps between frames.

    bash -lc 'source /etc/profile.d/pynq_venv.sh && python3 adc_frames.py --att 14 --n 20 --out meas/adc_frames'
-> <out>.npz: env_<mode> (n, N/BLK) mean power per BLK samples (dBFS), and the run parameters
"""
import argparse
import socket
import time
import numpy as np
from jscc_rx import JsccRx
import jscc_udp as U

ap = argparse.ArgumentParser()
ap.add_argument("--att", type=float, default=14.0, help="extra TX attenuation (GUI scale)")
ap.add_argument("--top", type=float, default=32.0, help="extra dB to go to first (then step down to --att)")
ap.add_argument("--att0", type=float, default=4.0)
ap.add_argument("--src", default="preset:div2k_0802")
ap.add_argument("--modes", default="sscc,jscc")
ap.add_argument("--n", type=int, default=20, help="captures per mode")
ap.add_argument("--len", type=int, default=2_000_000, help="samples per capture (20 MSPS)")
ap.add_argument("--blk", type=int, default=8)
ap.add_argument("--raw", type=int, default=0, help="also keep the raw IQ (int16) of the first RAW captures per mode")
ap.add_argument("--out", default="meas/adc_frames")
args = ap.parse_args()

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1.0)
TX = ("192.168.4.1", U.PORT_TX)


def tx(cmd):
    """send a command, return the ATTS answer (preview image chunks after a HELLO are skipped)"""
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


rx = JsccRx(download=False)
orig = tx(U.HELLO)
print("TX at start:", orig, flush=True)
out = dict(att=args.att, top=args.top, att0=args.att0, src=args.src, blk=args.blk, len=args.len)
try:
    print(tx(U.SRC + b" " + args.src.encode()), flush=True)
    for mode in args.modes.split(","):
        print(tx(U.MODE + b" " + mode.encode()), flush=True)
        tx(U.ATTN + b" %.2f" % (args.att0 + args.top)); time.sleep((args.top + 2) / 10 + 4)    # up at 10 dB/s
        print(tx(U.ATTN + b" %.2f 0" % (args.att0 + args.att)), flush=True); time.sleep(4)   # down: at once
        env, raw = [], []
        for k in range(args.n):
            x = rx.capture_adc(args.len, trig="now", timeout=2.0)
            if k < args.raw:
                raw.append(np.stack([x.real, x.imag], -1).astype(np.int16))
            p = (x.real ** 2 + x.imag ** 2).reshape(-1, args.blk).mean(1) / 2048.0 ** 2
            env.append(10 * np.log10(np.maximum(p, 1e-12)).astype(np.float32))
            time.sleep(0.05)
        out[f"env_{mode}"] = np.stack(env)
        if raw:
            out[f"raw_{mode}"] = np.stack(raw)
        print(f"{mode}: {args.n} captures, CAP_OVF {rx.rd('CAP_OVF')}", flush=True)
finally:
    f = orig.split() if orig else []
    if len(f) >= 5:                                   # JSCC-ATTS <db> <target> <mode> <src>
        tx(U.MODE + b" " + f[3].encode()); tx(U.SRC + b" " + f[4].encode()); tx(U.ATTN + b" " + f[2].encode() + b" 0")
    print("TX restored:", tx(U.HELLO), flush=True)
np.savez_compressed(args.out + ".npz", **out)
print("saved", args.out + ".npz", flush=True)
