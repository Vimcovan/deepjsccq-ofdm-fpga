"""Minimal v4l2-ctl replacement (the board image has no v4l-utils): list / get / set camera controls through the
V4L2 ioctls. Works while another process (tx_camera.py) is streaming.

    python3 v4l2ctl.py [/dev/video0] list
    python3 v4l2ctl.py [/dev/video0] set saturation=90 contrast=40
"""
import ctypes
import fcntl
import os
import sys

V4L2_CTRL_FLAG_NEXT_CTRL = 0x80000000
V4L2_CTRL_FLAG_DISABLED = 0x0001


class QueryCtrl(ctypes.Structure):
    _fields_ = [("id", ctypes.c_uint32), ("type", ctypes.c_uint32), ("name", ctypes.c_char * 32),
                ("minimum", ctypes.c_int32), ("maximum", ctypes.c_int32), ("step", ctypes.c_int32),
                ("default_value", ctypes.c_int32), ("flags", ctypes.c_uint32), ("reserved", ctypes.c_uint32 * 2)]


class Control(ctypes.Structure):
    _fields_ = [("id", ctypes.c_uint32), ("value", ctypes.c_int32)]


def _iowr(nr, size):
    return (3 << 30) | (size << 16) | (ord("V") << 8) | nr


VIDIOC_QUERYCTRL = _iowr(36, ctypes.sizeof(QueryCtrl))
VIDIOC_G_CTRL = _iowr(27, ctypes.sizeof(Control))
VIDIOC_S_CTRL = _iowr(28, ctypes.sizeof(Control))


def key(name):
    return name.decode().lower().replace(",", "").replace("(", "").replace(")", "").replace(" ", "_")


def controls(fd):
    q = QueryCtrl(); q.id = V4L2_CTRL_FLAG_NEXT_CTRL
    out = {}
    while True:
        try:
            fcntl.ioctl(fd, VIDIOC_QUERYCTRL, q)
        except OSError:
            break
        if not q.flags & V4L2_CTRL_FLAG_DISABLED and q.type != 6:          # 6 = control class header
            c = Control(q.id)
            try:
                fcntl.ioctl(fd, VIDIOC_G_CTRL, c); val = c.value
            except OSError:
                val = None
            out[key(q.name)] = dict(id=q.id, min=q.minimum, max=q.maximum, step=q.step, default=q.default_value,
                                    value=val, type=q.type)
        q.id |= V4L2_CTRL_FLAG_NEXT_CTRL
    return out


if __name__ == "__main__":
    args = sys.argv[1:]
    dev = args.pop(0) if args and args[0].startswith("/dev/") else "/dev/video0"
    fd = os.open(dev, os.O_RDWR)
    ctl = controls(fd)
    if not args or args[0] == "list":
        for k, c in ctl.items():
            print(f"{k:34s} {c['value']!s:>6}  (min {c['min']}, max {c['max']}, step {c['step']}, default {c['default']})")
    elif args[0] == "set":
        for kv in args[1:]:
            k, v = kv.split("=")
            fcntl.ioctl(fd, VIDIOC_S_CTRL, Control(ctl[k]["id"], int(v)))
            print(f"{k} = {controls(fd)[k]['value']}")
