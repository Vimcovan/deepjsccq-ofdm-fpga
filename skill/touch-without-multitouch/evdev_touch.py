"""Finger down / move / up from a multi-touch HID panel that the kernel drives with hid-generic (no hid-multitouch).

With hid-generic every report also carries the empty finger slots, which clear BTN_TOUCH, so X / libinput see each
touch as an instant tap: no press-and-hold, no drag. The ABS_X / ABS_Y of finger 0 are still reported continuously
while the finger is down (~90 reports/s on the tested panel) and once as X = Y = 0 when it is lifted. This reader
turns that into down / move / up callbacks in screen pixels. Taps still reach the toolkit through X as normal clicks;
use this only for hold / drag.

    t = EvdevTouch(EvdevTouch.find("USB2IIC_CTP"), (1024, 600),
                   down=lambda x, y: ..., move=lambda x, y: ..., up=lambda: ...)
    threading.Thread(target=t.run, daemon=True).start()

Needs read access to /dev/input/eventN (root, or the input group). In a Qt program, emit signals from the callbacks
(the callbacks run in the reader thread).
"""
import os
import select
import struct
import time

EV_SYN, EV_ABS, ABS_X, ABS_Y, SYN_REPORT = 0, 3, 0, 1, 0
EVENT = struct.Struct("llHHi")                  # struct input_event on 64-bit Linux (timeval = 2 x long)


class EvdevTouch:
    def __init__(self, path, size, down, move, up, full=32767, gap=0.15):
        self.path, (self.w, self.h) = path, size
        self.down, self.move, self.up = down, move, up
        self.full = full                         # logical maximum of ABS_X / ABS_Y (see /proc/bus/input/devices or evtest)
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
                    gx = int(x * (self.w - 1) / self.full)
                    gy = int(y * (self.h - 1) / self.full)
                    if lifted:
                        if active:
                            active = False
                            self.up()
                    elif not active:
                        active = True
                        self.down(gx, gy)
                    else:
                        self.move(gx, gy)


if __name__ == "__main__":                       # print the gestures: python3 evdev_touch.py [name part] [W H]
    import sys
    dev = EvdevTouch.find(sys.argv[1] if len(sys.argv) > 1 else "CTP")
    size = (int(sys.argv[2]), int(sys.argv[3])) if len(sys.argv) > 3 else (1024, 600)
    print("device", dev)
    EvdevTouch(dev, size, lambda x, y: print("down", x, y), lambda x, y: print("move", x, y),
               lambda: print("up")).run()
