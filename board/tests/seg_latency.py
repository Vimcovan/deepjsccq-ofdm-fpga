"""Segment latency, step 2 (PC): pair the PL counter events of pl_events.py frame by frame and split the latency.

    python seg_latency.py meas/seg/tx_events.csv meas/seg/rx_events.csv meas/seg/segments
-> <out>.json (per segment: median, p1, p99, min, max, n) and <out>_<segment>.csv per-frame values (ms)

Pairing follows the data flow: for each event of the earlier stage the first event of the later stage inside a
window that is physically possible (a frame takes 33.3 ms at 30 fps, so minimum-delay pairing would be ambiguous):
  PS take -> encoder input start   (0, 10) ms      encoder input start -> end   (20, 40) ms
  encoder input start -> FB_FRAMES  (0, 15) ms      (first OFDM sample of the frame written: encoder output starts)
  encoder input end -> SYM_FRAMES   (0, 15) ms      (last encoder symbol: encoding done)
  SYM_FRAMES -> TX_FRAMES           (0, 10) ms      air start = TX_FRAMES - 54960 / 20 MSPS
  air start -> SYNC_CNT             (0, 10) ms      across the boards (clock offset interpolated, 5 s samples)
  SYNC_CNT -> PHY_FRAMES            (0, 10) ms      SYNC_CNT -> IMG_FRAMES (5, 70) ms: an IMG_FRAMES ~0.2 ms after
                                                    a sync belongs to the previous frame (decoding takes ~33 ms)
  IMG_FRAMES -> IMG_SENT            [0, 5) ms       IMG_SENT -> PS has the image   (0, 30) ms
"""
import json
import sys
import numpy as np

AIR = 54960 / 20e6                                     # one PHY frame on the air, s


def load(fn):
    ev = {}
    for line in open(fn).read().splitlines()[1:]:
        t, n, v = line.split(",")
        ev.setdefault(n, []).append(float(t))
    return {n: np.array(sorted(x)) for n, x in ev.items()}


def nxt(a, b, lo, hi):
    """for each a: first b with lo <= b - a < hi (s), else nan"""
    i = np.searchsorted(b, a + lo, side="left")
    out = np.full(len(a), np.nan)
    ok = i < len(b)
    out[ok] = b[i[ok]]
    out[~(out - a < hi)] = np.nan
    return out


tx, rx = load(sys.argv[1]), load(sys.argv[2])
out = sys.argv[3]
ct, co = rx["clk"], None
clk = [l.split(",") for l in open(sys.argv[2]).read().splitlines()[1:] if ",clk," in l]
ct = np.array([float(c[0]) for c in clk]); co = np.array([int(c[2]) for c in clk]) * 1e-6       # TX - RX clock
rtt = np.array([int(l.split(",")[2]) for l in open(sys.argv[2]).read().splitlines()[1:] if ",clk_rtt," in l]) * 1e-3
to_rx = lambda t_tx: t_tx - np.interp(t_tx, ct + co, co)
ms = 1e-3

# per frame, anchored on the PS take time of the TX (one row per frame)
f = {"ps_take": tx["ps_take_src"]}
f["enc_in_start"] = nxt(f["ps_take"], tx["img_start"], 0, 10 * ms)
f["enc_in_end"] = nxt(f["enc_in_start"], tx["img_end"], 20 * ms, 40 * ms)
f["enc_out_start"] = nxt(f["enc_in_start"], tx["FB_FRAMES"], 0, 15 * ms)
f["enc_out_end"] = nxt(f["enc_in_end"], tx["SYM_FRAMES"], 0, 15 * ms)
f["air_end_tx"] = nxt(f["enc_out_end"], tx["TX_FRAMES"], 0, 10 * ms)
f["air_start"] = to_rx(f["air_end_tx"] - AIR)                          # RX clock from here on
f["rx_sync"] = nxt(f["air_start"], rx["SYNC_CNT"], 0, 10 * ms)
f["rx_phy_end"] = nxt(f["rx_sync"], rx["PHY_FRAMES"], 0, 10 * ms)
f["dec_end"] = nxt(f["rx_sync"], rx["IMG_FRAMES"], 5 * ms, 70 * ms)
f["dec_sent"] = nxt(f["dec_end"], rx["IMG_SENT"], 0, 5 * ms)
f["ps_img"] = nxt(f["dec_sent"], rx["ps_img"], 0, 30 * ms)
f["ps_take_rx"] = to_rx(f["ps_take"])
f["next_sync"] = nxt(f["rx_sync"], rx["SYNC_CNT"], 5 * ms, 60 * ms)

segs = [  # name, from, to, meaning
    ("1_tx_ps_to_encoder", "ps_take", "enc_in_start", "TX PS takes the frame -> first image byte into the encoder (PS)"),
    ("2_encoder_input", "enc_in_start", "enc_in_end", "image bytes flowing into the encoder (DMA, paced by the encoder)"),
    ("3a_encoder_first_out", "enc_in_start", "enc_out_start", "first byte in -> first symbol out (encoder pipeline)"),
    ("3b_encoder_tail", "enc_in_end", "enc_out_end", "last byte in -> last symbol out (encoder pipeline)"),
    ("4_tx_buffer_to_air", "enc_out_end", "air_end_tx", "last symbol -> frame finished on the air (OFDM + frame buffer + 2.75 ms air)"),
    ("5_air_start_to_rx_sync", "air_start", "rx_sync", "frame starts on the air -> first RX PHY data symbol (preamble, sync, CE)"),
    ("6_rx_phy_frame", "rx_sync", "rx_phy_end", "first -> last RX PHY symbol"),
    ("7_decoding", "rx_sync", "dec_end", "first RX PHY symbol -> last decoded byte"),
    ("7b_decoding_after_last_symbol", "rx_phy_end", "dec_end", "last RX PHY symbol -> last decoded byte"),
    ("8_rx_pl_to_dma", "dec_end", "dec_sent", "last decoded byte -> forwarded to the PS DMA path"),
    ("9_rx_ps_receive", "dec_sent", "ps_img", "image forwarded -> PS has it (DMA + rx_server, first UDP chunk)"),
    ("PL_encoder_in_to_decoder_out", "enc_in_start", "dec_end", "first image byte into the encoder -> last decoded byte (TX clock -> RX clock)"),
    ("TX_PS_take_to_air_start", "ps_take", "air_end_tx", None),
    ("END_TO_END_ps_to_ps", "ps_take_rx", "ps_img", "TX PS takes the frame -> RX PS has the decoded image"),
]
res = {}
for name, a, b, meaning in segs:
    if a == "enc_in_start" and b == "dec_end":
        d = f[b] - to_rx(f[a])
    elif name == "TX_PS_take_to_air_start":
        d = f[b] - AIR - f[a]
    else:
        d = f[b] - f[a]
    d = d[d == d] * 1e3
    res[name] = dict(median=round(float(np.median(d)), 3), p1=round(float(np.percentile(d, 1)), 3),
                     p99=round(float(np.percentile(d, 99)), 3), min=round(float(d.min()), 3),
                     max=round(float(d.max()), 3), n=int(len(d)), meaning=meaning or "TX PS takes the frame -> frame starts on the air")
    np.savetxt(f"{out}_{name}.csv", d, fmt="%.4f")
# decoder coupling check: does the decoder finish frame k right after frame k+1 arrives (flush by the next frame)?
dd = (f["dec_end"] - f["next_sync"]) * 1e3; per = (f["next_sync"] - f["rx_sync"]) * 1e3; m = (dd == dd) & (per == per)
res["_decoder_end_minus_next_sync"] = dict(median=round(float(np.median(dd[m])), 3), p1=round(float(np.percentile(dd[m], 1)), 3),
                                           p99=round(float(np.percentile(dd[m], 99)), 3),
                                           corr_decoding_vs_frame_period=round(float(np.corrcoef((f["dec_end"] - f["rx_sync"])[m], per[m])[0, 1]), 3),
                                           frame_period_ms_p1_p99=[round(float(np.percentile(per[m], 1)), 3), round(float(np.percentile(per[m], 99)), 3)])
res["_clock"] = dict(offset_drift_us=round(float((co[-1] - co[0]) * 1e6), 1), rtt_ms_median=round(float(np.median(rtt)), 3),
                     n_sync=int(len(co)), frame_air_ms=AIR * 1e3, frames=int(len(f["ps_take"])))
json.dump(res, open(out + ".json", "w"), indent=1)
print(f"{'segment':32s} {'median':>8s} {'p1':>8s} {'p99':>8s} {'min':>8s} {'max':>8s} {'n':>6s}  (ms)")
for k, r in res.items():
    if not k.startswith("_"):
        print(f"{k:32s} {r['median']:8.3f} {r['p1']:8.3f} {r['p99']:8.3f} {r['min']:8.3f} {r['max']:8.3f} {r['n']:6d}")
for k in ("_decoder_end_minus_next_sync", "_clock"):
    print(k, res[k])

# three segments as in the GLOBECOM 2025 paper (encoder / transmission / decoder), PL only, contiguous:
#   encoding      first image byte into the encoder -> last encoder symbol out           (TX clock)
#   transmission  last encoder symbol -> last RX PHY symbol out (frame buffer, air, sync, CE, demodulation)
#   decoding      last RX PHY symbol -> last decoded byte                                 (RX clock)
three = {"encoding": f["enc_out_end"] - f["enc_in_start"],
         "transmission": f["rx_phy_end"] - to_rx(f["enc_out_end"]),
         "decoding": f["dec_end"] - f["rx_phy_end"]}
three["total_PL"] = f["dec_end"] - to_rx(f["enc_in_start"])
res3 = {}
for k, d in three.items():
    d = d[d == d] * 1e3
    res3[k] = dict(median=round(float(np.median(d)), 3), min=round(float(d.min()), 3), max=round(float(d.max()), 3),
                   p1=round(float(np.percentile(d, 1)), 3), p99=round(float(np.percentile(d, 99)), 3), n=int(len(d)))
    np.savetxt(f"{out}_3seg_{k}.csv", d, fmt="%.4f")
json.dump(res3, open(out + "_3seg.json", "w"), indent=1)
print("\nthree segments (ms):")
for k, r in res3.items():
    print(f"  {k:13s} median {r['median']:8.3f}  min {r['min']:8.3f}  max {r['max']:8.3f}  p1 {r['p1']:8.3f}  p99 {r['p99']:8.3f}  n {r['n']}")
print(f"  sum of medians {sum(res3[k]['median'] for k in ('encoding', 'transmission', 'decoding')):.3f}")
