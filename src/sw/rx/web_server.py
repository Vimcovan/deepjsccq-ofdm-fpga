"""Web control page for the DeepJSCC-Q link, served by the RX board (phone / tablet / PC browser over WiFi).

    python3 web_server.py [--port 8080] [--rx 127.0.0.1]      (jscc-web.service)

Both boards and the phone are on the same WiFi (e.g. the phone's hotspot); each board streams its own picture to the
phone, nothing is relayed between the boards over the WiFi:
    TX board  http://<TX>:8081/tx.mjpg   frames handed to the encoder (tx_camera.py --http-port)
    RX board  http://<RX>:8080/          this page;  /rx.mjpg decoded image;  /ws state + commands (WebSocket)
rx_server sends this process JPEG images ("JSCC-HELLO 2 jpg": every 2nd, MT_RX_JPG), SSCC packets and telemetry. The TX board is
found with a STAT datagram broadcast on the WiFi subnet (it answers ATTS without subscribing); its answers give the
attenuation / mode / source. With the touch-screen GUI running (jscc_gui.py --remote-port 5010) and the boards
cabled, PSNR / latency / frame rate come from the GUI and commands go through it, so its controls stay in step;
otherwise commands go straight to the TX board over the WiFi. PSNR needs both pictures in one place: shown only
while the boards are cabled (from the GUI).
"""
import argparse
import asyncio
import collections
import json
import multiprocessing as mp
import os
import socket
import subprocess
import time

import cv2
import numpy as np
import tornado.ioloop
import tornado.iostream
import tornado.web
import tornado.websocket

import jscc_udp as U
import sscc_pkt

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8080)
ap.add_argument("--rx", default="127.0.0.1")
ap.add_argument("--att0", type=float, default=0.0, help="TX attenuation at extra = 0 (tx_camera.py --att)")
ap.add_argument("--gui-port", type=int, default=5010, help="jscc_gui.py --remote-port")
ap.add_argument("--tx-http-port", type=int, default=8081, help="tx_camera.py --http-port")
ap.add_argument("--wifi", default="wlan0")
args = ap.parse_args()

HERE = os.path.dirname(os.path.abspath(__file__))
# subcarrier layout (fftshift order, index = subcarrier + 32), as jscc_gui.py
NULLS = set(range(0, 6)) | {32} | set(range(59, 64))
PILOTS = [11, 25, 39, 53]
DATA = [k for k in range(64) if k not in NULLS and k not in PILOTS]
LTF_ONE = [6, 7, 10, 11, 13, 15, 16, 17, 18, 19, 20, 23, 24, 26, 28, 29, 30, 31, 33, 36, 37, 39, 41, 47, 48, 51, 53, 55,
           56, 57, 58]
LTF_MINUS = [8, 9, 12, 14, 21, 22, 25, 27, 34, 35, 38, 40, 42, 43, 44, 45, 46, 49, 50, 52, 54]
USED = np.array(sorted(LTF_ONE + LTF_MINUS))
QAM_LV = np.array([-1106, -790, -474, -158, 158, 474, 790, 1106])
NSYM, PAD = 683, 16
GRAY_JPG = cv2.imencode(".jpg", np.full((256, 256, 3), 128, np.uint8))[1].tobytes()   # SSCC frame the JPEG decoder
CABLE_NETS = ("192.168.3.", "192.168.4.")                                              # rejects (as the GUI)


def evm_db(z):
    r = QAM_LV[np.argmin(abs(z.real[..., None] - QAM_LV), -1)] + 1j * QAM_LV[np.argmin(abs(z.imag[..., None] - QAM_LV), -1)]
    return float(10 * np.log10(np.mean(abs(z - r) ** 2) / np.mean(abs(r) ** 2)))


def wifi_broadcast():
    """directed broadcast address of the WiFi interface, or None"""
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr", "show", args.wifi], capture_output=True, text=True, timeout=2).stdout
        f = out.split()
        return f[f.index("brd") + 1] if "brd" in f else None
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return None


# ------------------------------------------------------------------ network process (as jscc_gui.net_proc)
def net_proc(conn, cmdq, active):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.bind(("0.0.0.0", 0)); sock.settimeout(0.2)
    ra = U.Reassembler(); t_hello = t_stat = t_brd = t_tx = 0.0; brd = None; tx = None
    while True:
        now = time.time()
        if tx and now - t_tx > 3.0:                     # TX silent (rebooted, other WiFi / address): search again
            tx = None; t_brd = 0.0
        while not cmdq.empty():
            c = cmdq.get_nowait()
            if tx:
                try:
                    sock.sendto(c, (tx, U.PORT_TX))
                except OSError:
                    pass
        if active.value and now - t_hello > 1.0:
            t_hello = now
            try:
                sock.sendto(U.HELLO + b" %d jpg" % max(1, round(30 / U.STREAM_FPS)), (args.rx, U.PORT_RX))
            except OSError:
                pass
        if active.value and now - t_stat > 1.0:          # TX state; broadcast while its address is not known
            t_stat = now
            if now - t_brd > 10.0:
                t_brd, brd = now, wifi_broadcast()
            for a in ([tx] if tx else []) + ([brd] if brd and not tx else []):
                try:
                    sock.sendto(U.STAT, (a, U.PORT_TX))
                except OSError:
                    pass
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            continue
        except OSError:
            continue
        if data.startswith(U.ATTS):
            if not addr[0].startswith(CABLE_NETS):
                tx, t_tx = addr[0], time.time()
            f = data[len(U.ATTS):].split()
            try:
                conn.send(("atten", float(f[0]), float(f[1]), f[2].decode() if len(f) > 2 else "jscc",
                           f[3].decode() if len(f) > 3 else "camera", time.time(), addr[0]))
            except (ValueError, IndexError):
                pass
            continue
        m = ra.add(data)
        if m is not None:
            conn.send((m[0], m[1], m[2], time.time()))


# ------------------------------------------------------------------ link state (main process)
class Link:
    def __init__(self):
        self.rate = collections.deque(maxlen=60); self.t_tel = 0.0
        self.jpg = None; self.seq = 0
        self.att = self.att_target = None; self.mode = "jscc"; self.source = None; self.t_att = 0.0
        self.tx_ip = None; self.t_tx_ip = 0.0
        self.t_sscc_ok = 0.0; self.sscc_hist = collections.deque(maxlen=60)
        self.st_hist = collections.deque(); self.rates = {}; self.status = {}
        self.ltf_sig = collections.deque(maxlen=16); self.ltf_noi = collections.deque(maxlen=16)
        self.evm = self.snr = self.snr_sc = self.const = self.spec = None
        self.gui = {}; self.t_gui = 0.0                     # last "status" answer of the touch-screen GUI

    def gui_now(self):
        return self.gui if time.time() - self.t_gui < 2.0 else None

    def cur_mode(self):
        g = self.gui_now()
        if g and g.get("tx_link"):
            return g["mode"]
        if time.time() - self.t_att < 3.0:
            return self.mode
        return "sscc" if time.time() - self.t_sscc_ok < 1.5 else "jscc"

    def show(self, jpg, t):
        self.jpg = jpg; self.seq += 1; self.rate.append(t)

    def on_sscc(self, pkt, t):
        p = sscc_pkt.unpack(pkt)
        self.sscc_hist.append(p["ok"])
        if p["ok"]:
            self.t_sscc_ok = t
        if self.cur_mode() != "sscc":
            return
        a = cv2.imdecode(np.frombuffer(p["jpeg"], np.uint8), cv2.IMREAD_COLOR) if p["jpeg"] else None
        self.show(p["jpeg"] if a is not None and a.shape == (256, 256, 3) else GRAY_JPG, t)

    def on_tel(self, meta, arrays, t):
        self.t_tel = t
        st = meta.get("status", {}); self.status = st
        self.st_hist.append((t, st))
        while len(self.st_hist) > 2 and t - self.st_hist[0][0] > 2.0:
            self.st_hist.popleft()
        if len(self.st_hist) >= 2:
            (ta, sa), (tb, sb) = self.st_hist[0], self.st_hist[-1]
            self.rates = {k: (sb.get(k, 0) - sa.get(k, 0)) / max(1e-3, tb - ta) for k in ("SYNC_CNT", "IMG_FRAMES")}
        if meta.get("spec"):
            self.spec = meta["spec"]
        tail = meta.get("start_sym", 0) + 19 == NSYM - 1
        if arrays.get("pre") is not None:                  # LTF1 / LTF2: per-subcarrier SNR (as jscc_gui.add_ltf)
            P = np.asarray(arrays["pre"]).reshape(-1, 64)
            if len(P) - 20 == 2:
                y1, y2 = P[0], P[1] * np.exp(-1j * np.angle(np.vdot(P[0][USED], P[1][USED])))
                n = abs((y1 - y2)[USED]) ** 2 / 2
                self.ltf_noi.append(n); self.ltf_sig.append(abs(((y1 + y2) / 2)[USED]) ** 2 - n / 2)
                sg, nz = np.mean(self.ltf_sig, 0), np.maximum(np.mean(self.ltf_noi, 0), 1e-9)
                self.snr_sc = 10 * np.log10(np.maximum(sg, 1e-9) / nz)
                self.snr = float(10 * np.log10(max(float(sg.sum()), 1e-9) / float(nz.sum())))
        if arrays.get("cpe") is not None:
            S = np.asarray(arrays["cpe"]).reshape(-1, 64)
            d = S[:, DATA].ravel()
            if tail:
                d = d[:-PAD]
            self.evm = evm_db(d)
            self.const = d[::max(1, len(d) // 1500)]       # ~1500 points are enough for the phone

    def on_atten(self, db, target, mode, source, t, ip):
        self.att, self.att_target, self.mode, self.source, self.t_att = db, target, mode, source, t
        if not ip.startswith(CABLE_NETS):                  # the TX board's WiFi address: phones can reach it
            self.tx_ip, self.t_tx_ip = ip, t

    def fps(self):
        q = self.rate
        if not q or time.time() - q[-1] > 1.5:
            return 0.0
        return (len(q) - 1) / (q[-1] - q[0]) if len(q) > 2 and q[-1] > q[0] else 0.0

    def state(self, phy):
        """phy: with the constellation / per-subcarrier SNR / spectrum (only for pages showing them: WiFi budget)"""
        now = time.time()
        g = self.gui_now(); cabled = bool(g and g.get("tx_link"))
        tx_ok = cabled or now - self.t_att < 3.0
        r = lambda v, n=1: None if v is None else round(float(v), n)
        if cabled:
            att_t, src = g.get("att_target"), g.get("src")
        else:
            att_t = self.att_target - args.att0 if tx_ok and self.att_target is not None and self.att_target >= 0 else None
            src = self.source if tx_ok else None
        tx_url = (f"http://{self.tx_ip}:{args.tx_http_port}/tx.mjpg"
                  if self.tx_ip and now - self.t_tx_ip < 10.0 else None)
        s = dict(t=now, gui=bool(g), cabled=cabled, tx_link=tx_ok, tx_url=tx_url, mode=self.cur_mode(), source=src,
                 att_target=r(att_t, 2), fps=r(g["rx_fps"]) if g else r(self.fps()), img_fps=r(self.fps()),
                 psnr=g.get("psnr") if cabled else None, lat=g.get("lat") if cabled else None,
                 evm=r(self.evm), snr=r(self.snr), sync=r(self.rates.get("SYNC_CNT"), 1),
                 agc=self.status.get("AGC_GAIN_IDX"), agc_lock=self.status.get("AGC_LOCK"),
                 sscc_ok=r(np.mean(self.sscc_hist), 2) if self.sscc_hist else None, tel=now - self.t_tel < 2.0)
        if not phy:
            return s
        if self.const is not None:
            s["const"] = np.round(np.stack([self.const.real, self.const.imag], 1) / 1106, 3).ravel().tolist()
        if self.snr_sc is not None:
            s["snr_sc"] = np.round(self.snr_sc, 1).tolist(); s["sc"] = (USED - 32).tolist()
        if self.spec:
            s["spec"] = {k: np.round(np.asarray(self.spec[k], float), 1).tolist() for k in ("f", "sig", "noi")}
        return s


link = Link()
conn, child = mp.Pipe(duplex=False)
cmdq = mp.Queue(); active = mp.Value("b", 0, lock=False)
proc = mp.Process(target=net_proc, args=(child, cmdq, active), daemon=True)
gsock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); gsock.setblocking(False)   # GUI remote control (UDP)
proc.start()
clients = set(); streams = {"rx": 0}


def pump():
    """drain the network pipe"""
    tel = None
    while conn.poll():
        m = conn.recv()
        if m[0] == "atten":
            link.on_atten(*m[1:])
            continue
        mtype, mid, payload, t = m
        if mtype == U.MT_RX_JPG:
            if link.cur_mode() != "sscc":
                link.show(payload, t)
        elif mtype == U.MT_SSCC and len(payload) == sscc_pkt.PAY_BYTES:
            link.on_sscc(payload, t)
        elif mtype == U.MT_TEL:
            tel = (payload, t)
    if tel:
        meta, arrays = U.unpack_tel(tel[0]); link.on_tel(meta, arrays, tel[1])
    active.value = 1 if clients or any(streams.values()) else 0
    while True:                                            # GUI status answers
        try:
            data, _ = gsock.recvfrom(4096)
        except OSError:
            break
        try:
            link.gui = json.loads(data.decode()); link.t_gui = time.time()
        except ValueError:
            pass


def gui_cmd(line):
    try:
        gsock.sendto(line.encode(), ("127.0.0.1", args.gui_port))
    except OSError:
        pass


def poll_gui():
    if clients:
        gui_cmd("status")


# ------------------------------------------------------------------ HTTP
class Index(tornado.web.RequestHandler):
    def get(self):
        self.set_header("Cache-Control", "no-cache")
        with open(os.path.join(HERE, "web", "index.html"), "rb") as f:
            self.write(f.read())


class Mjpeg(tornado.web.RequestHandler):
    async def get(self):
        self.set_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.set_header("Cache-Control", "no-cache")
        sock = self.request.connection.stream.socket
        streams["rx"] += 1; last = -1; t_sent = time.time()
        try:
            while True:
                await asyncio.sleep(0.01)
                now = time.time()
                if link.seq == last or link.jpg is None or now - t_sent < 0.8 / U.STREAM_FPS:
                    continue
                if U.unsent(sock) > U.STREAM_BACKLOG:          # WiFi behind: skip frames; phone gone: close
                    if now - t_sent > U.STREAM_STALL:
                        break
                    continue
                last = link.seq; b = link.jpg; t_sent = now
                self.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % len(b) + b + b"\r\n")
                await self.flush()
        except tornado.iostream.StreamClosedError:
            pass
        finally:
            streams["rx"] -= 1


class Ws(tornado.websocket.WebSocketHandler):
    def open(self):
        self.phy = False; clients.add(self)

    def on_close(self):
        clients.discard(self)

    def on_message(self, msg):
        try:
            c = json.loads(msg)
        except ValueError:
            return
        if c.get("cmd") == "tab":
            self.phy = c.get("tab") == "phy"; return
        g = link.gui_now(); via_gui = bool(g and g.get("tx_link"))   # cabled: through the GUI (its controls follow)
        if c.get("cmd") == "att":
            extra = min(max(float(c.get("extra", 0)), 0.0), 60.0)
            gui_cmd("atten %.2f" % extra) if via_gui else cmdq.put(U.ATTN + b" %.2f" % (args.att0 + extra))
        elif c.get("cmd") == "mode" and c.get("mode") in ("jscc", "sscc"):
            gui_cmd("mode " + c["mode"]) if via_gui else cmdq.put(U.MODE + b" " + c["mode"].encode())
        elif c.get("cmd") == "src" and c.get("src") in ("camera", "video", "preset"):
            gui_cmd("src " + c["src"]) if via_gui else cmdq.put(U.SRC + b" " + c["src"].encode())


def broadcast():
    if not clients:
        return
    msg = {}
    for c in list(clients):
        if c.ws_connection is None or c.ws_connection.is_closing():
            clients.discard(c); continue
        if c.phy not in msg:
            msg[c.phy] = json.dumps(link.state(c.phy))
        c.write_message(msg[c.phy]).add_done_callback(lambda f: f.exception())   # a closed socket is not an error here


app = tornado.web.Application([(r"/", Index), (r"/rx\.mjpg", Mjpeg), (r"/ws", Ws)])
app.listen(args.port)
tornado.ioloop.PeriodicCallback(pump, 10).start()
tornado.ioloop.PeriodicCallback(broadcast, 250).start()
tornado.ioloop.PeriodicCallback(poll_gui, 250).start()
print(f"web control on port {args.port} (rx {args.rx}, TX found on {args.wifi})", flush=True)
tornado.ioloop.IOLoop.current().start()
