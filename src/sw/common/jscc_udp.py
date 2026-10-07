"""UDP protocol shared by the boards (tx_camera.py, rx_server.py) and the PC GUI (jscc_gui.py).

Every datagram: 20-byte header + payload (<= CHUNK bytes, no IP fragmentation on the USB-Ethernet link)
    magic  4s  b"JSCC"
    mtype  B   message type (MT_*)
    flags  B   0
    chunk  H   chunk index
    nchunk H   number of chunks of this message
    pad    H   0
    msg_id I   message counter (frame id)
    total  I   total message length (bytes)
A message is complete when all nchunk chunks with the same (mtype, msg_id) arrived; incomplete ones are dropped.
Subscription: the PC sends b"JSCC-HELLO" to the board's control port about once a second; the board streams to the
address/port the last HELLO came from (no PC address is configured on the boards).
"""
import struct
import json
import numpy as np

MAGIC = b"JSCC"
HDR = struct.Struct("<4sBBHHHII")
CHUNK = 1400
HELLO = b"JSCC-HELLO"
PORT_TX = 5006            # TX board (camera preview)
PORT_RX = 5005            # RX board (decoded images + telemetry)

MT_RX_IMG = 1             # decoded image, 196608 bytes uint8 (256, 256, 3)
MT_TEL = 2                # telemetry + status: u32 json length, json, raw int16 arrays (see pack_tel)
MT_TX_IMG = 3             # camera frame handed to the encoder, 196608 bytes
# TX attenuation (demo of graceful degradation, needs the TX bitstream with PS SPI access, VERSION >= 2):
#   GUI -> TX port   ATTN + b" <dB> [<rate>]"  target TX1 attenuation (0..89.75 dB, 0.25 dB steps); the TX board
#                                              ramps up at <rate> dB/s (default tx_camera --att-up-dbs; 0 = at once;
#                                              the RX AGC alone follows only a slowly falling level, the rx_server AGC
#                                              guard unsticks it) and steps down at once
#   TX  -> GUI       ATTS + b" <dB> <target>"  current / target attenuation; answer to ATTN and to every HELLO
#   TX  -> GUI       ATTS + b" <dB> <target> <mode> <source>"   (dB = -1: no attenuation control; mode jscc / sscc;
#                    source camera / video / preset:<name>)
#   GUI -> TX port   SRC + b" camera" | b" video" | b" preset:<name>" | b" preset"   input: USB camera, the demo video
#                    (looped) or a still test image (tx_camera --presets, 30 fps); " preset" steps
#                    video -> preset 1 .. n -> video (from the camera: video)
#   GUI -> TX port   MODE + b" jscc" | b" sscc"   DeepJSCC or the SSCC baseline (JPEG + conv. code + 64-QAM)
#   TX  -> GUI       TS + b" <frame id> <t>"    with every preview: TX time.time() when the frame was taken from its
#                    source (before JPEG / encoder); not starting with MAGIC, so receivers that do not know it drop it
#   GUI -> TX port   TIME                     -> TX answers TIME_R + b" <t>" (its time.time(), for clock offset)
TS = b"TXTS"
TIME = b"JSCC-TIME"
TIME_R = b"TXTIME"
ATTN = b"JSCC-ATTN"
ATTS = b"JSCC-ATTS"
MODE = b"JSCC-MODE"
SRC = b"JSCC-SRC"
MT_SSCC = 4               # SSCC packet decoded by the RX PL (12272 bytes, sscc_pkt.py), RX board -> GUI


def chunks(mtype, msg_id, payload):
    n = max(1, (len(payload) + CHUNK - 1) // CHUNK)
    for k in range(n):
        yield HDR.pack(MAGIC, mtype, 0, k, n, 0, msg_id & 0xFFFFFFFF, len(payload)) + payload[k * CHUNK:(k + 1) * CHUNK]


class Reassembler:
    """Collects chunks; returns (mtype, msg_id, payload) when a message is complete."""
    def __init__(self, keep=8):
        self.parts = {}
        self.keep = keep
        self.dropped = 0

    def add(self, data):
        if len(data) < HDR.size:
            return None
        magic, mtype, _, k, n, _, mid, total = HDR.unpack_from(data)
        if magic != MAGIC:
            return None
        key = (mtype, mid)
        ent = self.parts.get(key)
        if ent is None:
            ent = self.parts[key] = [n, total, {}]
            # forget old incomplete messages of the same type
            old = [kk for kk in self.parts if kk[0] == mtype and kk != key]
            for kk in sorted(old, key=lambda x: x[1])[:-self.keep]:
                del self.parts[kk]; self.dropped += 1
        ent[2][k] = data[HDR.size:]
        if len(ent[2]) == ent[0]:
            del self.parts[key]
            payload = b"".join(ent[2][i] for i in range(ent[0]))
            return mtype, mid, payload[:ent[1]]
        return None


def pack_tel(meta, arrays):
    """meta: json-able dict; arrays: dict name -> complex ndarray (stored as int16 I/Q pairs, shapes in meta)."""
    meta = dict(meta)
    meta["_arrays"] = {k: list(v.shape) for k, v in arrays.items()}
    js = json.dumps(meta).encode()
    raw = b"".join(np.stack([v.real, v.imag], -1).astype("<i2").tobytes() for v in arrays.values())
    return struct.pack("<I", len(js)) + js + raw


def unpack_tel(payload):
    n = struct.unpack_from("<I", payload)[0]
    meta = json.loads(payload[4:4 + n].decode())
    off = 4 + n
    arrays = {}
    for k, shp in meta.pop("_arrays", {}).items():
        cnt = int(np.prod(shp)) * 2
        a = np.frombuffer(payload, "<i2", cnt, off).astype(np.float32).reshape(*shp, 2)
        arrays[k] = a[..., 0] + 1j * a[..., 1]
        off += cnt * 2
    return meta, arrays
