#!/bin/bash
# Read-only probe of the board's local display stack (run as root on the board).
echo "--- connectors ---"
for c in /sys/class/drm/card*-*; do [ -e "$c/status" ] && echo "$(basename $c): $(cat $c/status)"; done
echo "--- X server ---"
systemctl is-active pynq-x11.service 2>/dev/null | sed 's/^/pynq-x11.service: /'
pgrep -a Xorg | head -2 || echo "no Xorg running"
export DISPLAY=${DISPLAY:-:0} XAUTHORITY=${XAUTHORITY:-/root/.Xauthority}
if xset -q >/dev/null 2>&1; then
  echo "X reachable on $DISPLAY (XAUTHORITY=$XAUTHORITY)"
  xrandr 2>/dev/null | grep -E ' connected|\*' | head -6
  xset -q | grep -E 'timeout:|DPMS is'
  WA=`xprop -root _NET_WORKAREA 2>/dev/null | cut -d= -f2 | cut -d, -f1-4`
  echo "work area _NET_WORKAREA: $WA"
else echo "X not reachable on $DISPLAY"; fi
grep -E 'Driver' /etc/X11/xorg.conf 2>/dev/null | head -3
echo "--- input devices ---"
awk '/^N: Name=/{n=$0} /^H: Handlers=/{print n" | "$0}' /proc/bus/input/devices
for d in /sys/bus/hid/devices/*; do [ -e "$d/driver" ] && echo "hid $(basename $d) -> $(basename $(readlink -f $d/driver))"; done 2>/dev/null
{ zcat /proc/config.gz 2>/dev/null; } | grep -E 'CONFIG_HID_MULTITOUCH[ =]' || true
echo "--- Python GUI stack (PYNQ venv) ---"
. /etc/profile.d/pynq_venv.sh 2>/dev/null
python3 -c "from PyQt5 import QtCore; print('PyQt5', QtCore.PYQT_VERSION_STR, 'Qt', QtCore.QT_VERSION_STR)" 2>&1 | tail -1
python3 -c "import pyqtgraph; print('pyqtgraph', pyqtgraph.__version__)" 2>&1 | tail -1
echo "--- CPU ---"; nproc; uptime
