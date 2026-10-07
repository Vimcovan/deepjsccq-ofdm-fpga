"""measure_link.py --frame-log output (<out>_frames.npz) -> one CSV per window for MATLAB (plot_fps_latency.m):
    t_min      arrival time of the frame at the RX board, minutes from the window start
    fps        instantaneous frame rate = 1 / (arrival interval to the previous frame)
    lat_ms     end-to-end latency (TX source -> RX decoded image), ms (empty: frame without TX time / undecodable)
    psnr       dB;  decoded 0/1

    python frames_to_csv.py meas/lat_video_10min_frames.npz   -> meas/lat_video_10min_<mode>_<att>.csv
"""
import sys
import numpy as np

src = sys.argv[1]
d = np.load(src)
base = src[:-len("_frames.npz")]
for i in range(int(d["n"])):
    mode, att = str(d[f"mode_{i}"]), float(d[f"att_{i}"])
    t = d[f"t_{i}"]; order = np.argsort(t)
    t, lat, ps, dec = t[order], d[f"lat_{i}"][order], d[f"psnr_{i}"][order], d[f"decoded_{i}"][order]
    fps = np.r_[np.nan, 1.0 / np.maximum(np.diff(t), 1e-6)]
    fn = f"{base}_{mode}_{att:g}dB.csv"
    with open(fn, "w") as f:
        f.write("t_min,fps,lat_ms,psnr,decoded\n")
        for a, b, c, p, q in zip((t - t[0]) / 60, fps, lat, ps, dec):
            f.write(f"{a:.6f},{'' if b != b else f'{b:.3f}'},{'' if c != c else f'{c:.3f}'},{p:.3f},{int(q)}\n")
    ok = lat[lat == lat]
    print(f"{fn}: {len(t)} frames, {t[-1] - t[0]:.1f} s, mean fps {(len(t) - 1) / (t[-1] - t[0]):.2f}, "
          f"latency median {np.median(ok):.2f} ms (p1 {np.percentile(ok, 1):.2f}, p99 {np.percentile(ok, 99):.2f}), "
          f"n lat {len(ok)}")
