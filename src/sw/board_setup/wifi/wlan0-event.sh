#!/bin/sh
# wpa_cli action script (wlan0-event.service): $1 = interface, $2 = CONNECTED / DISCONNECTED.
# On every (re)connection restart the DHCP client: after a switch between two hotspots of the same name dhclient keeps
# the old lease (renewal days later) and the board is unreachable on the new one.
[ "$2" = CONNECTED ] || exit 0
logger -t wlan0-event "$1 connected: renewing DHCP lease"
systemctl restart wlan0-dhcp
