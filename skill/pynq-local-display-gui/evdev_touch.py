"""Finger down / move / up from a multi-touch HID panel that the kernel drives with hid-generic (no hid-multitouch).

With hid-generic every report also carries the empty finger slots, which clear BTN_TOUCH, so X / libinput see each
touch as an instant tap: no press-and-hold, no drag. The ABS_X / ABS_Y of finger 0 are still reported continuously
while the finger is down (~90 reports/s on the tested panel) and once as X = Y = 0 when it is lifted. This reader
turns that into down / move / up callbacks in screen pixels. Taps still reach the toolkit through X as normal clicks;
use this only for hold / drag.

    t = EvdevTouch(EvdevTouch.find("<part of the device name>"), (1024, 600),
                   down=lambda x, y: ..., move=lambda x, y: ..., up=lambda: ...)
    threading.Thread(target=t.run, daemon=True).start()

Needs read access to /dev/input/eventN (root, or the input group). In a Qt program, emit signals from the callbacks
(the callbacks run in the reader thread).
"""
import fcntl
import os
import select
import struct
import time

EV_SYN, EV_ABS, ABS_X, ABS_Y, SYN_REPORT = 0, 3, 0, 1, 0
EVENT = struct.Struct("llHHi")                  # struct input_event on 64-bit Linux (timeval = 2 x long)
ABSINFO = struct.Struct("6i")                    # value, minimum, maximum, fuzz, flat, resolution


def abs_range(fd, code):
    """(minimum, maximum) of an absolute axis: EVIOCGABS(code) = _IOR('E', 0x40 + code, struct input_absinfo)"""
    req = (2 << 30) | (ABSINFO.size << 16) | (ord("E") << 8) | (0x40 + code)
    _, lo, hi, _, _, _ = ABSINFO.unpack(fcntl.ioctl(fd, req, bytes(ABSINFO.size)))
    return lo, hi


class EvdevTouch:
    def __init__(self, path, size, down, move, up, gap=0.15):
        self.path, (self.w, self.h) = path, size
        self.down, self.move, self.up = down, move, up
        self.gap = gap                           # no report for gap s while down = lifted (a missed release report)

    @staticmethod
    def find(name_part):
        """/dev/input/eventN of the device whose name contains name_part, or None."""
        for blk in open("/proc/bus/input/devices").read().split("\n\n"):
            if name_part in blk:
                ev = [w for w in blk.split() if w.startswith("event")]
                if ev:
                    return "/dev/input/" + ev[0]
        return None

    def run(self):
        fd = os.open(self.path, os.O_RDONLY | os.O_NONBLOCK)
        (x0, x1), (y0, y1) = abs_range(fd, ABS_X), abs_range(fd, ABS_Y)   # panel's logical coordinate range
        x = y = 0
        fx = fy = None
        active, t_last = False, 0.0
        while True:
            r, _, _ = select.select([fd], [], [], 0.05)
            if not r:
                if active and time.time() - t_last > self.gap:
                    active = False
                    self.up()
                continue
            try:
                buf = os.read(fd, EVENT.size * 64)
            except BlockingIOError:
                continue
            for i in range(0, len(buf) - EVENT.size + 1, EVENT.size):
                _, _, typ, code, val = EVENT.unpack_from(buf, i)
                if typ == EV_ABS and code in (ABS_X, ABS_Y):         # finger 0
                    if code == ABS_X:
                        fx = val
                    else:
                        fy = val
                elif typ == EV_SYN and code == SYN_REPORT:           # end of one HID report
                    x = x if fx is None else fx
                    y = y if fy is None else fy
                    lifted = fx == 0 and fy == 0
                    fx = fy = None
                    t_last = time.time()
                    gx = int((x - x0) * (self.w - 1) / max(x1 - x0, 1))
                    gy = int((y - y0) * (self.h - 1) / max(y1 - y0, 1))
                    if lifted:
                        if active:
                            active = False
                            self.up()
                    elif not active:
                        active = True
                        self.down(gx, gy)
                    else:
                        self.move(gx, gy)


if __name__ == "__main__":                       # print the gestures: python3 evdev_touch.py <name part> <W> <H>
    import sys
    if len(sys.argv) < 4:
        sys.exit("usage: python3 evdev_touch.py <part of the device name> <screen W> <screen H>")
    dev = EvdevTouch.find(sys.argv[1])
    size = (int(sys.argv[2]), int(sys.argv[3]))
    fd = os.open(dev, os.O_RDONLY)
    print("device", dev, "ABS_X range", abs_range(fd, ABS_X), "ABS_Y range", abs_range(fd, ABS_Y))
    os.close(fd)
    EvdevTouch(dev, size, lambda x, y: print("down", x, y), lambda x, y: print("move", x, y),
               lambda: print("up")).run()
