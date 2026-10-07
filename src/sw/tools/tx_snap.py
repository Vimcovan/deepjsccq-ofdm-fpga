"""Grab TX camera frames (the 256x256 images handed to the encoder) from the TX preview stream.

    python3 tx_snap.py out.png [n]      (run where 192.168.4.1 is reachable, e.g. on the RX board)
Saves the n-th complete frame and prints mean colour / saturation statistics.
"""
import socket
import sys
import time
import numpy as np
from PIL import Image
import jscc_udp as U

out = sys.argv[1] if len(sys.argv) > 1 else "tx_snap.png"
n = int(sys.argv[2]) if len(sys.argv) > 2 else 5
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(0.5)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
ra = U.Reassembler(); got = 0; t_hello = 0
t0 = time.time()
while got < n and time.time() - t0 < 15:
    if time.time() - t_hello > 1:
        s.sendto(U.HELLO, ("192.168.4.1", U.PORT_TX)); t_hello = time.time()
    try:
        d, _ = s.recvfrom(65536)
    except socket.timeout:
        continue
    r = ra.add(d)
    if r and r[0] == U.MT_TX_IMG and len(r[2]) == 256 * 256 * 3:
        got += 1; img = np.frombuffer(r[2], np.uint8).reshape(256, 256, 3)
if not got:
    sys.exit("no TX preview frames")
Image.fromarray(img).save(out)
hsv = np.asarray(Image.fromarray(img).convert("HSV")).astype(float)
print(f"{out}: mean RGB {img.reshape(-1, 3).mean(0).round(1).tolist()}, mean saturation {hsv[..., 1].mean():.1f}/255, "
      f"value p5/p50/p95 {np.percentile(hsv[..., 2], [5, 50, 95]).round(0).tolist()}")
