#!/bin/bash
# RX board touch screen (1024x600 via the DP->HDMI adapter): 52.01 MHz pixel clock / 60.00 Hz instead of the EDID
# preferred 51.2 MHz / 59.99 Hz. 18 x 51.2 MHz = 921.6 MHz lies inside the OFDM band (915 +- 8 MHz) and is picked up by
# the RX as a spur comb at +6.6 MHz (lines at the 38.1 kHz line rate); 52.01 MHz harmonics: 884.3 / 936.2 MHz (out of
# band). Called by jscc-gui.service before the GUI starts; does nothing if the mode is already active.
OUT=DP-1
xrandr | grep -q "^$OUT connected" || exit 0
xrandr --verbose | grep -q "52.010MHz.*\*current" && exit 0
id=$(xrandr --verbose | grep -E "^ +1024x600 \(0x[0-9a-f]+\) +52\.010MHz" | head -1 | sed -E 's/.*\((0x[0-9a-f]+)\).*/\1/')
if [ -z "$id" ]; then                        # not in the EDID / default list: define it (same timing as the 60.00 Hz mode)
    xrandr --newmode 1024x600_52 52.01 1024 1072 1104 1344 600 603 604 645 +hsync +vsync 2>/dev/null
    xrandr --addmode $OUT 1024x600_52 && id=1024x600_52
fi
xrandr --output $OUT --off; sleep 2              # off -> on: the adapter re-locks (a direct mode switch may leave it dark)
xrandr --output $OUT --mode "$id" --pos 0x0 --primary || xrandr --output $OUT --auto
