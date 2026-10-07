"""Segment latency, step 1 (read only, runs next to the services): PL counter events time-stamped by tight PS polling.

    TX board:  python3 pl_events.py tx --dur 90 --out tx_events.csv
    RX board:  python3 pl_events.py rx --dur 90 --out meas/rx_events.csv

Every change of a polled counter is logged as (t, name, value) with t = time.time() of the board (poll period
~40 us). Counter timing from the RTL (2026-10-07):
  TX  IMG_BYTES   +1 per image byte taken by the encoder -> img_start / img_end: first / last byte of a transfer
                  burst (bursts separated by >= 1 ms without bytes; the 32-bit count wraps, so no v // 196608)
      FB_FRAMES   first OFDM sample of a frame written into the TX frame buffer (encoder output starts)
      SYM_FRAMES  last encoder symbol handed to the OFDM baseband (encoding done)
      TX_FRAMES   last sample of a frame handed to the DAC (air start = this - 54960 / 20 MSPS)
  RX  SYNC_CNT    first data symbol out of the RX PHY (after preamble detection and channel estimation)
      PHY_FRAMES  last symbol out of the RX PHY
      IMG_FRAMES  last byte of a decoded image out of the decoder
      IMG_SENT    last byte of an image forwarded to the PS DMA path
Also logged: TX  'ps_take' (frame id) from the TXTS datagrams of tx_camera (PS took the frame from its source);
             RX  'ps_img' (message id) first UDP chunk of each decoded image from rx_server (PS has the image),
                 'clk' (TX clock - RX clock in us, round trip in us) every 5 s from JSCC-TIME queries.
"""
import argparse
import socket
import struct
import time
from pynq import MMIO
import jscc_udp as U

ap = argparse.ArgumentParser()
ap.add_argument("board", choices=("tx", "rx"))
ap.add_argument("--dur", type=float, default=90.0)
ap.add_argument("--tx", default="192.168.4.1")
ap.add_argument("--out", required=True)
args = ap.parse_args()

TX = args.board == "tx"
REGS = (dict(IMG_BYTES=0x10, FB_FRAMES=0x20, SYM_FRAMES=0x18, TX_FRAMES=0x1C) if TX else
        dict(SYNC_CNT=0x20, PHY_FRAMES=0x24, IMG_FRAMES=0x34, IMG_SENT=0x38))
IMG = 256 * 256 * 3
reg = MMIO(0x8002_0000, 0x1_0000)
rd = reg.read
names, addrs = list(REGS), list(REGS.values())

sk = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sk.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
sk.bind(("0.0.0.0", 0)); sk.setblocking(False)
local = ("127.0.0.1", U.PORT_TX if TX else U.PORT_RX)

ev = []
prev = [rd(a) for a in addrs]
IDLE = 1e-3                                           # s without encoder input bytes that separates two frames
img_last, img_open = 0.0, False
last_msg, t_hello, t_clk, q_clk = None, 0.0, 0.0, None
t_end = time.time() + args.dur
while True:
    t = time.time()
    if t > t_end:
        break
    for k, a in enumerate(addrs):
        v = rd(a)
        if v != prev[k]:
            n = names[k]
            if n == "IMG_BYTES":                      # encoder input bursts (the 32-bit count wraps: no v // IMG)
                if t - img_last > IDLE:
                    ev.append((t, "img_start", v))    # first bytes after an idle gap: a frame transfer started
                img_last, img_open = t, True
            else:
                ev.append((t, n, v))
            prev[k] = v
    if TX and img_open and t - img_last > IDLE:       # no new bytes for IDLE: the transfer ended at img_last
        ev.append((img_last, "img_end", prev[0]))
        img_open = False
    if t - t_hello > 1.0:                             # subscribe to the local service (previews / decoded images)
        t_hello = t
        sk.sendto(U.HELLO, local)
    if not TX and t - t_clk > 5.0:                    # clock offset query to the TX board
        t_clk = q_clk = t
        sk.sendto(U.TIME, (args.tx, U.PORT_TX))
    try:
        while True:
            d = sk.recv(65536)
            if TX and d.startswith(U.TS):
                f = d.split(); ev.append((t, "ps_take", int(f[1]))); ev.append((float(f[2]), "ps_take_src", int(f[1])))
            elif not TX and d.startswith(U.TIME_R) and q_clk is not None:
                t2 = time.time(); off = float(d.split()[1]) - (q_clk + t2) / 2
                ev.append((t2, "clk", int(round(off * 1e6)))); ev.append((t2, "clk_rtt", int(round((t2 - q_clk) * 1e6))))
                q_clk = None
            elif not TX and len(d) >= U.HDR.size and d[:4] == U.MAGIC:
                _, mtype, _, k, n, _, mid, total = U.HDR.unpack_from(d)
                if mtype == U.MT_RX_IMG and mid != last_msg:
                    last_msg = mid; ev.append((t, "ps_img", mid))
    except BlockingIOError:
        pass

with open(args.out, "w") as f:
    f.write("t,name,value\n")
    for t, n, v in ev:
        f.write(f"{t:.6f},{n},{v}\n")
print(f"saved {args.out}: {len(ev)} events in {args.dur:.0f} s")
