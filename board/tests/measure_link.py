"""Link measurement: image quality vs TX attenuation, DeepJSCC-Q and the SSCC baseline (same frames, same power).

Runs on the RX board (reaches both the TX board's preview stream and the local rx_server):
    python3 measure_link.py [--att 0,4,8,...] [--passes 2] [--settle 3] [--dwell 8] [--out meas_link]

PSNR (cv2.PSNR) against the TX preview of the same frame (the frames handed to the encoder): SSCC packets carry the
frame number (= preview message id) -> exact pairing when the CRC is right; JSCC images (no frame number) and SSCC
packets with a wrong CRC: best matching preview, as in the GUI (JSCC: last 350 ms, measured latency ~40 ms; SSCC: all
buffered). Per attenuation point:
    psnr_decoded   frames the receiver could decode (JSCC: every image; SSCC: JPEG decodes)
    psnr_shown     what a viewer sees: every received frame; one the JPEG decoder rejects is a mid-gray image (as the GUI)
    decoded        fraction of received SSCC packets the JPEG decoder accepts (JSCC: 1)
    crc_ok         SSCC packets with a correct CRC
    evm_db         final constellation EVM (telemetry 'cpe', same formula as the GUI), sync/s, AGC gain, latency
    snr_db         two-LTF SNR (noise |Y1 - Y2|^2 / 2, as the GUI), averaged over the window; snr_sc_db per used
                   subcarrier; snr_dd_db decision directed on the final constellation
Results: <out>.json (all points, all passes) and <out>.csv (one row per point and pass).
--src preset:<name>   TX input for the run (default: the demo video)
--top <dB>            before each sweep the attenuation goes to att0 + top first and the link settles there (the AGC
                      only has to follow rising levels); the points are then measured in the given order (descending)
--save-img <dir>      per point the decoded image whose PSNR is closest to the point mean (PNG, + the TX reference)
"""
import argparse
import collections
import json
import multiprocessing as mp
import queue
import time
import numpy as np
import cv2
import jscc_udp as U
import sscc_pkt

ap = argparse.ArgumentParser()
ap.add_argument("--att", default="0,4,8,12,16,18,20,22,24,26,28,30,32", help="extra TX attenuation points, dB")
ap.add_argument("--modes", default="jscc,sscc")
ap.add_argument("--passes", type=int, default=2)
ap.add_argument("--settle", type=float, default=3.0, help="s after the attenuation reached the point")
ap.add_argument("--dwell", type=float, default=8.0, help="measurement time per point, s")
ap.add_argument("--att0", type=float, default=4.0, help="TX attenuation of the config LUT (extra = 0)")
ap.add_argument("--tx", default="192.168.4.1")
ap.add_argument("--rx", default="127.0.0.1")
ap.add_argument("--out", default="meas_link")
ap.add_argument("--diag", action="store_true", help="SSCC: PSNR against frame numbers -2..+2 (pairing check)")
ap.add_argument("--src", default="video", help="TX input: video, camera or preset:<name>")
ap.add_argument("--top", type=float, default=None, help="extra dB to settle at before each sweep (then descend)")
ap.add_argument("--top-settle", type=float, default=5.0, help="s at the top attenuation before the sweep")
ap.add_argument("--save-img", default=None, help="directory for one decoded PNG per point")
ap.add_argument("--save-const", default=None, help="directory for the final constellations of every telemetry "
                "snapshot per point (<mode>_<att>.npz: cpe (n, 20, 64) complex64, start_sym (n,))")
ap.add_argument("--frame-log", action="store_true", help="per received frame: arrival time, end-to-end latency, PSNR, "
                "decoded -> <out>_frames.npz")
args = ap.parse_args()
DIAG = args.diag

QAM_LV = np.array([-1106, -790, -474, -158, 158, 474, 790, 1106])
NULLS = set(range(0, 6)) | {32} | set(range(59, 64)); PILOTS = [11, 25, 39, 53]
DATA = [k for k in range(64) if k not in NULLS and k not in PILOTS]
NSYM, PAD = 683, 16
FAIL_IMG = np.full((256, 256, 3), 128, np.uint8)       # SSCC frame the JPEG decoder rejects
LTF_ONE = [6, 7, 10, 11, 13, 15, 16, 17, 18, 19, 20, 23, 24, 26, 28, 29, 30, 31, 33, 36, 37, 39, 41, 47, 48, 51, 53, 55, 56, 57, 58]
LTF_MINUS = [8, 9, 12, 14, 21, 22, 25, 27, 34, 35, 38, 40, 42, 43, 44, 45, 46, 49, 50, 52, 54]
USED = np.array(sorted(LTF_ONE + LTF_MINUS))


def evm_db(z):
    ref = QAM_LV[np.argmin(abs(z.real[:, None] - QAM_LV), 1)] + 1j * QAM_LV[np.argmin(abs(z.imag[:, None] - QAM_LV), 1)]
    return 10 * np.log10(np.mean(abs(z - ref) ** 2) / np.mean(abs(ref) ** 2))


tx_state = {}                                          # last ATTS: db, target, mode, src
# UDP reception in two processes (TX previews / rx_server), as the GUI does: one Python loop cannot keep up with two
# 30 fps image streams (~8400 datagrams/s) and loses chunks; messages are reassembled there and passed on whole
MODE_FLAG = mp.Value("b", 0, lock=False)               # 0 jscc, 1 sscc: the receivers drop the stream of the other mode
CMD_Q, MSG_Q = mp.Queue(), mp.Queue()


def net_proc(peer, msg_q, cmd_q, mode_flag):
    import socket as so
    sk = so.socket(so.AF_INET, so.SOCK_DGRAM)
    sk.setsockopt(so.SOL_SOCKET, so.SO_RCVBUF, 16 << 20)
    sk.bind(("0.0.0.0", 0)); sk.settimeout(0.02)
    rasm = U.Reassembler(); t_h = 0.0
    drop = {U.MT_RX_IMG: 1, U.MT_SSCC: 0}               # message type -> mode in which it is not needed
    while True:
        now = time.time()
        if now - t_h > 1.0:
            sk.sendto(U.HELLO, peer); t_h = now
        if cmd_q is not None:
            try:
                while True:
                    sk.sendto(cmd_q.get_nowait(), peer)
            except queue.Empty:
                pass
        try:
            d, _ = sk.recvfrom(65536)
        except so.timeout:
            continue
        if d.startswith(U.ATTS):
            msg_q.put(("ATTS", 0, d, now)); continue
        if d.startswith(U.TS):                            # TX source time of a preview frame
            msg_q.put(("TS", 0, d, now)); continue
        if len(d) < U.HDR.size or d[:4] != U.MAGIC:
            continue
        if drop.get(d[4], -1) == mode_flag.value:
            continue
        m = rasm.add(d)
        if m is not None:
            msg_q.put((m[0], m[1], m[2], time.time()))


def ctrl(msg):
    CMD_Q.put(msg)


class Window:
    """statistics of one measurement window"""
    def __init__(self):
        self.ps_dec, self.ps_shown, self.lat = [], [], []
        self.raw = []                                 # per scored frame: (RX arrival t, TX source t or nan, PSNR, decoded)
        self.offs = []                                # (RX t, TX clock - RX clock) samples during the window
        self.syncs = []                               # RX times at which a clock query started
        self.n_amb = 0                                # decoded frames whose best-match pairing was ambiguous
        self.n_sync_ex = 0                            # frames excluded for arriving < SYNC_GUARD after a clock query
        self.n_img = self.n_sscc = self.n_crc_ok = self.n_dec = 0
        self.evm, self.status = [], []
        self.ltf_sig, self.ltf_noi, self.snr_dd = [], [], []
        self.imgs = []                                # (PSNR, decoded image) for --save-img
        self.const = []                               # (start_sym, cpe (20, 64)) for --save-const
        self.q = []
        self.mtypes = collections.Counter()           # complete messages per type (diagnostics)
        self.diag = collections.defaultdict(list)     # --diag: SSCC PSNR vs frame number offset


txbuf = collections.deque(maxlen=120)                 # (t, img, small, frame id): 4 s of previews
pending = []                                          # SSCC frames waiting for their preview (t, img, frame, decoded)
pending_ok = False                                    # True while flushing: no further deferral
last_shown = None
win = None
tsmap = collections.OrderedDict()                     # TX frame id -> TX source time (TX clock)
RTT = None                                            # round trip of the clock_offset() answer used, ms
SYNC_GUARD = 0.5                                      # s after a clock query start whose frames get no latency


def clock_offset(n=30):
    """TX clock minus RX clock from n TIME queries (the answer with the shortest round trip); returns (offset, rtt)"""
    import socket as so
    sk = so.socket(so.AF_INET, so.SOCK_DGRAM); sk.settimeout(0.2)
    best = None
    for _ in range(n):
        t1 = time.time(); sk.sendto(U.TIME, (args.tx, U.PORT_TX))
        try:
            while True:
                d = sk.recv(65536)
                if d.startswith(U.TIME_R):
                    break
        except so.timeout:
            continue
        t2 = time.time()
        if best is None or t2 - t1 < best[1]:
            best = (float(d.split()[1]) - (t1 + t2) / 2, t2 - t1)
        time.sleep(0.02)
    sk.close()
    return best


AMBIG = 0.5                                           # best match must have < AMBIG x the MSE of the second best


def best_ref(img, t, window=True, ambiguity=False):
    """most similar TX preview; with ambiguity=True returns (entry, ambiguous): ambiguous = the second best candidate
    is nearly as similar (repeated / still content, e.g. the loop point of the demo video) -> latency not trusted"""
    cand = ([e for e in txbuf if -0.05 < t - e[0] < 0.35] if window else []) or list(txbuf)
    if not cand:
        return (None, True) if ambiguity else None
    rc = img[::4, ::4].astype(np.float32)
    mse = sorted((float(np.mean((rc - e[2]) ** 2)), k) for k, e in enumerate(cand))
    best = cand[mse[0][1]]
    if not ambiguity:
        return best
    return best, len(mse) > 1 and mse[0][0] >= AMBIG * mse[1][0]


def score(img, t, w, decoded, frame=None, window=True):
    """PSNR of a shown image; decoded=False: a mid-gray image is shown (as the GUI); frame: TX frame number (exact)"""
    global last_shown
    if decoded:
        last_shown = img
    shown = img if decoded else FAIL_IMG
    if shown is None or not txbuf:
        return
    e = None
    if frame is not None:
        e = next((x for x in reversed(txbuf) if x[3] & 0xFFFF == frame), None)
        if e is None and not pending_ok:                   # the TX sends the preview after the packet: wait for it
            pending.append((t, img, frame, decoded)); return
        if DIAG and decoded:                               # PSNR against neighbouring frame numbers (pairing check)
            for off in range(-2, 3):
                x = next((x for x in reversed(txbuf) if x[3] & 0xFFFF == (frame + off) & 0xFFFF), None)
                if x is not None:
                    w.diag[off].append(float(cv2.PSNR(img, x[1])))
    amb = False
    if e is None:
        e, amb = best_ref(img if decoded else shown, t, window, ambiguity=True)
        w.n_amb += bool(decoded and amb)
    if e is None:
        return
    # an undecodable frame (mid-gray) is compared with the TX frame of now: the newest preview
    ref_now = e[1] if decoded else txbuf[-1][1]
    ps = float(cv2.PSNR(shown, ref_now))
    w.ps_shown.append(ps)
    w.raw.append((t, tsmap.get(e[3], float("nan")) if decoded and not amb else float("nan"), ps, bool(decoded)))
    if decoded:
        w.ps_dec.append(ps); w.lat.append((t - e[0]) * 1e3)
        if args.save_img:
            w.imgs.append((ps, shown))


def flush_pending(now, new_id=None):
    """score pending SSCC frames whose preview arrived (or that waited > 0.5 s: best match)"""
    global pending_ok
    if not pending or win is None:
        pending.clear(); return
    keep = []
    pending_ok = True
    for (t, img, frame, decoded) in pending:
        if (new_id is not None and new_id & 0xFFFF == frame) or now - t > 0.5:
            restore_shown(img, decoded); score(img, t, win, decoded, frame=frame, window=False)
        else:
            keep.append((t, img, frame, decoded))
    pending_ok = False
    pending[:] = keep


def restore_shown(img, decoded):
    """pending frames are scored late: last_shown must be their own decoded image"""
    global last_shown
    if decoded:
        last_shown = img


def pump(until):
    """process received messages until time `until`"""
    while time.time() < until:
        try:
            mtype, mid, payload, t = MSG_Q.get(timeout=0.05)
        except queue.Empty:
            continue
        if mtype == "TS":
            f = payload.split()
            tsmap[int(f[1])] = float(f[2])
            while len(tsmap) > 600:
                tsmap.popitem(last=False)
            continue
        if mtype == "ATTS":
            f = payload[len(U.ATTS):].split()
            tx_state.update(db=float(f[0]), target=float(f[1]), mode=f[2].decode() if len(f) > 2 else "?",
                            src=f[3].decode() if len(f) > 3 else "?")
            continue
        if win is not None:
            win.mtypes[mtype] += 1
        if mtype == U.MT_TX_IMG and len(payload) == 256 * 256 * 3:
            img = np.frombuffer(payload, np.uint8).reshape(256, 256, 3)
            txbuf.append((t, img, img[::4, ::4].astype(np.float32), mid))
            flush_pending(t, mid)
        elif win is None:
            continue
        elif mtype == U.MT_RX_IMG and len(payload) == 256 * 256 * 3 and tx_state.get("mode") == "jscc":
            win.n_img += 1; win.n_dec += 1
            score(np.frombuffer(payload, np.uint8).reshape(256, 256, 3), t, win, True)
        elif mtype == U.MT_SSCC and len(payload) == sscc_pkt.PAY_BYTES and tx_state.get("mode") == "sscc":
            p = sscc_pkt.unpack(payload)
            win.n_sscc += 1; win.n_crc_ok += bool(p["ok"])
            if p["ok"]:
                win.q.append(p["quality"])
            img = None
            if p["jpeg"]:
                a = cv2.imdecode(np.frombuffer(p["jpeg"], np.uint8), cv2.IMREAD_COLOR)
                if a is not None and a.shape == (256, 256, 3):
                    img = np.ascontiguousarray(a[:, :, ::-1])
            if img is not None:
                win.n_dec += 1
            score(img, t, win, img is not None, frame=p["frame"] if p["ok"] else None, window=False)
        elif mtype == U.MT_TEL:
            meta, arrays = U.unpack_tel(payload)
            st = meta.get("status", {})
            if st:
                win.status.append((t, st))
            if "cpe" in arrays:
                tail = meta.get("start_sym", 0) + 19 == NSYM - 1
                if args.save_const:
                    win.const.append((meta.get("start_sym", 0), np.asarray(arrays["cpe"]).reshape(-1, 64).astype(np.complex64)))
                Z = np.asarray(arrays["cpe"]).reshape(-1, 64)[:, DATA]
                z = Z.ravel()
                if tail:
                    z = z[:-PAD]
                win.evm.append(evm_db(z))
                if tail:
                    Z = Z[:-1]                                    # last OFDM symbol is partly zero padding
                ref = QAM_LV[np.argmin(abs(Z.real[..., None] - QAM_LV), -1)] + \
                    1j * QAM_LV[np.argmin(abs(Z.imag[..., None] - QAM_LV), -1)]
                win.snr_dd.append(10 * np.log10(np.mean(abs(ref) ** 2) / max(float(np.mean(abs(Z - ref) ** 2)), 1e-9)))
            if arrays.get("pre") is not None:                     # LTF1 / LTF2 (rows 0 / 1), as the GUI
                P = np.asarray(arrays["pre"]).reshape(-1, 64)
                if len(P) - 20 == 2:
                    y1, y2 = P[0], P[1] * np.exp(-1j * np.angle(np.vdot(P[0][USED], P[1][USED])))
                    n = abs((y1 - y2)[USED]) ** 2 / 2
                    win.ltf_noi.append(n); win.ltf_sig.append(abs(((y1 + y2) / 2)[USED]) ** 2 - n / 2)


def wait_for(cond, timeout, what):
    t_end = time.time() + timeout
    while time.time() < t_end:
        pump(time.time() + 0.2)
        if cond():
            return True
    print(f"  ! timeout waiting for {what} (TX state {tx_state})", flush=True)
    return False


def e2e(w):
    """per scored frame: end-to-end latency in ms (TX source time mapped to the RX clock with the clock offset
    interpolated between the samples taken during the window; nan without a TX time)"""
    if not w.raw or not w.offs:
        return np.full(len(w.raw), np.nan)
    a = np.array(w.raw, dtype=float); ot, ov = np.array(w.offs).T
    lat = (a[:, 0] - (a[:, 1] - np.interp(a[:, 0], ot, ov))) * 1e3
    near = np.zeros(len(a), bool)                     # the clock queries disturb the frames right after them
    for ts in w.syncs:
        near |= (a[:, 0] >= ts) & (a[:, 0] < ts + SYNC_GUARD)
    w.n_sync_ex = int(np.sum(near & (lat == lat)))
    lat[near] = np.nan
    return lat


def summary(w, mode, att, dt):
    lat_e2e = [v for v in e2e(w) if v == v]
    s = w.status
    sync = gain = None
    if len(s) >= 2:
        sync = (s[-1][1]["SYNC_CNT"] - s[0][1]["SYNC_CNT"]) / max(s[-1][0] - s[0][0], 1e-3)
        gain = float(np.median([x[1].get("AGC_GAIN_IDX", 0) for x in s]))
    pct = lambda a, q: round(float(np.percentile(a, q)), 2) if a else None
    n_rx = w.n_img if mode == "jscc" else w.n_sscc
    snr = snr_sc = None
    if w.ltf_sig:
        sg, nz = np.mean(w.ltf_sig, 0), np.maximum(np.mean(w.ltf_noi, 0), 1e-9)
        snr = round(10 * np.log10(max(float(sg.sum()), 1e-9) / float(nz.sum())), 2)
        snr_sc = [round(float(v), 1) for v in 10 * np.log10(np.maximum(sg, 1e-9) / nz)]
    return dict(mode=mode, att=att, src=args.src,
                snr_db=snr, snr_dd_db=round(float(np.mean(w.snr_dd)), 2) if w.snr_dd else None, n_ltf=len(w.ltf_sig), t=round(time.time(), 1), dwell=round(dt, 2),
                rx_fps=round(n_rx / dt, 2), frames=n_rx,
                psnr_decoded=round(float(np.mean(w.ps_dec)), 2) if w.ps_dec else None,
                psnr_decoded_p10=pct(w.ps_dec, 10), psnr_decoded_median=pct(w.ps_dec, 50),
                psnr_shown=round(float(np.mean(w.ps_shown)), 2) if w.ps_shown else None,
                psnr_shown_p10=pct(w.ps_shown, 10),
                decoded=round(w.n_dec / n_rx, 3) if n_rx else 0.0,
                crc_ok=round(w.n_crc_ok / w.n_sscc, 3) if (mode == "sscc" and w.n_sscc) else None,
                jpeg_quality=round(float(np.mean(w.q)), 1) if w.q else None,
                evm_db=round(float(np.mean(w.evm)), 2) if w.evm else None,
                sync_per_s=round(sync, 2) if sync is not None else None, agc_gain=gain,
                latency_ms=pct(w.lat, 50), n_psnr=len(w.ps_dec),
                latency_e2e_ms=pct(lat_e2e, 50), latency_e2e_p10=pct(lat_e2e, 10), latency_e2e_p90=pct(lat_e2e, 90),
                latency_e2e_mean=round(float(np.mean(lat_e2e)), 2) if lat_e2e else None, n_lat_e2e=len(lat_e2e),
                n_lat_ambiguous=w.n_amb, n_lat_sync_excluded=w.n_sync_ex,
                clock_offsets=[(round(t, 3), round(o * 1e3, 3)) for t, o in w.offs], clock_rtt_ms=RTT, msgs=dict(w.mtypes),
                diag={k: round(float(np.mean(v)), 2) for k, v in sorted(w.diag.items())} if w.diag else None,
                snr_sc_db=snr_sc)


def save_img(w, mode, att, ps):
    """decoded image with the PSNR closest to the point mean -> <dir>/<mode>_<att>.png; returns the file name"""
    if not args.save_img or not w.imgs:
        return None, None
    import os
    os.makedirs(args.save_img, exist_ok=True)
    m = float(np.mean([p for p, _ in w.imgs]))
    p, img = min(w.imgs, key=lambda x: abs(x[0] - m))
    fn = f"{mode}_{att:05.2f}dB_p{ps}.png"
    cv2.imwrite(os.path.join(args.save_img, fn), np.ascontiguousarray(img[:, :, ::-1]))
    if txbuf and not os.path.exists(os.path.join(args.save_img, "tx_reference.png")):
        cv2.imwrite(os.path.join(args.save_img, "tx_reference.png"), np.ascontiguousarray(txbuf[-1][1][:, :, ::-1]))
    return fn, round(p, 2)


for peer, cq in (((args.tx, U.PORT_TX), CMD_Q), ((args.rx, U.PORT_RX), None)):
    mp.Process(target=net_proc, args=(peer, MSG_Q, cq, MODE_FLAG), daemon=True).start()
atts = [float(a) for a in args.att.split(",")]
modes = args.modes.split(",")
results = []
FRAMES = []
pump(time.time() + 2.0)
orig = dict(tx_state)
print("TX state at start:", orig, flush=True)
try:
    ctrl(U.SRC + b" " + args.src.encode())
    wait_for(lambda: tx_state.get("src") == args.src, 5, f"source {args.src}")
    for ps in range(args.passes):
        for mode in modes:
            ctrl(U.MODE + b" " + mode.encode()); MODE_FLAG.value = int(mode == "sscc")
            last_shown = None                                     # no image of the other mode on the 'screen'
            a_start = args.att0 + (args.top if args.top is not None else 0.0)
            ctrl(U.ATTN + b" %.2f" % a_start)                     # up: TX ramp 10 dB/s
            wait_for(lambda: tx_state.get("mode") == mode and abs(tx_state.get("db", -9) - a_start) < 0.01, 15, f"mode {mode}")
            pump(time.time() + (args.top_settle if args.top is not None else 3.0))   # receiver settles there
            for att in atts:
                ctrl(U.ATTN + b" %.2f" % (args.att0 + att))
                wait_for(lambda: abs(tx_state.get("db", -9) - (args.att0 + att)) < 0.01, 10, f"attenuation {att}")
                pump(time.time() + args.settle)
                win = Window(); t0 = time.time()
                while time.time() < t0 + args.dwell:             # clock offset re-measured every 30 s (crystal drift)
                    win.syncs.append(time.time())
                    off = clock_offset(3)
                    if off is not None:
                        win.offs.append((time.time(), off[0])); RTT = round(off[1] * 1e3, 3)
                    pump(min(t0 + args.dwell, time.time() + 30.0))
                win.syncs.append(time.time())
                off = clock_offset(3)
                if off is not None:
                    win.offs.append((time.time(), off[0]))
                r = summary(win, mode, att, time.time() - t0); r["pass"] = ps
                r["img"], r["img_psnr"] = save_img(win, mode, att, ps)
                if args.save_const and win.const:
                    import os
                    os.makedirs(args.save_const, exist_ok=True)
                    r["const"] = f"{mode}_{att:05.2f}dB_p{ps}.npz"
                    np.savez_compressed(os.path.join(args.save_const, r["const"]),
                                        start_sym=np.array([s for s, _ in win.const]),
                                        cpe=np.stack([c for _, c in win.const]))
                if args.frame_log:
                    a = np.array(win.raw, dtype=float).reshape(-1, 4)
                    FRAMES.append(dict(mode=mode, att=att, t=a[:, 0], lat=e2e(win), psnr=a[:, 2], decoded=a[:, 3]))
                win = None
                results.append(r)
                print(f"pass {ps} {mode} +{att:4.1f} dB: PSNR dec {r['psnr_decoded']} shown {r['psnr_shown']} "
                      f"decoded {r['decoded']} crc {r['crc_ok']} SNR {r['snr_db']} EVM {r['evm_db']} sync {r['sync_per_s']} "
                      f"gain {r['agc_gain']} fps {r['rx_fps']} lat(preview) {r['latency_ms']} lat(e2e) {r['latency_e2e_ms']} "
                      f"[{r['latency_e2e_p10']}..{r['latency_e2e_p90']}] n {r['n_lat_e2e']} (ambiguous {r['n_lat_ambiguous']}, "
                      f"sync-excluded {r['n_lat_sync_excluded']}) rtt {r['clock_rtt_ms']} ms", flush=True)
                json.dump(dict(args=vars(args), results=results), open(args.out + ".json", "w"), indent=1)
finally:
    ctrl(U.ATTN + b" %.2f" % orig.get("target", args.att0))
    ctrl(U.MODE + b" " + orig.get("mode", "jscc").encode())
    if orig.get("src", "?") != "?":
        ctrl(U.SRC + b" " + orig["src"].encode())
    pump(time.time() + 1.0)
    print("restored TX:", tx_state, flush=True)
keys = [k for k in results[0] if not isinstance(results[0][k], (dict, list))] if results else []   # scalars (json: all)
with open(args.out + ".csv", "w") as fh:
    fh.write(",".join(keys) + "\n")
    for r in results:
        fh.write(",".join("" if r.get(k) is None else str(r[k]) for k in keys) + "\n")
print(f"saved {args.out}.json / .csv ({len(results)} points)", flush=True)
if args.frame_log and FRAMES:
    np.savez_compressed(args.out + "_frames.npz", **{f"{k}_{i}": np.asarray(v) for i, F in enumerate(FRAMES)
                                                      for k, v in F.items()}, n=len(FRAMES))
    print(f"saved {args.out}_frames.npz ({len(FRAMES)} windows, {sum(len(F['t']) for F in FRAMES)} frames)", flush=True)
