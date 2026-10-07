"""PL frame counters sampled at 1 Hz (read only, runs next to the services): the hardware frame rate without the PS.
    TX board:  python3 pl_counters.py tx --dur 600 --out tx_counters.csv   (SYM_FRAMES encoder frames, TX_FRAMES to DAC)
    RX board:  python3 pl_counters.py rx --dur 600 --out meas/rx_counters.csv
               (SYNC_CNT synchronised PHY frames, PHY_FRAMES, IMG_FRAMES decoded images, FB_DROP frame buffer drops)
CSV: t (s, board clock), one column per counter.
"""
import argparse
import time
from pynq import MMIO

ap = argparse.ArgumentParser()
ap.add_argument("board", choices=("tx", "rx"))
ap.add_argument("--dur", type=float, default=600.0)
ap.add_argument("--period", type=float, default=1.0)
ap.add_argument("--out", required=True)
args = ap.parse_args()

REGS = {"tx": dict(SYM_FRAMES=0x18, TX_FRAMES=0x1C, FB_FRAMES=0x20, TLAST_ERR=0x24),
        "rx": dict(SYNC_CNT=0x20, PHY_FRAMES=0x24, FB_IN=0x28, FB_DROP=0x2C, IMG_FRAMES=0x34)}[args.board]
reg = MMIO(0x8002_0000, 0x1_0000)
t0 = time.time(); k = 0
with open(args.out, "w") as f:
    f.write("t," + ",".join(REGS) + "\n")
    while True:
        t_next = t0 + k * args.period
        time.sleep(max(0.0, t_next - time.time()))
        f.write(f"{time.time():.6f}," + ",".join(str(reg.read(a)) for a in REGS.values()) + "\n"); f.flush()
        k += 1
        if k * args.period > args.dur:
            break
print("saved", args.out, k, "samples")
