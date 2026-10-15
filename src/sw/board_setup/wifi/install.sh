#!/bin/bash
# WiFi at boot for remote access (board's WILC module, 2.4 GHz only). Run as root:
#   bash install.sh "<SSID>" "<password>"
set -e
here=$(cd "$(dirname "$0")" && pwd)
umask 077
{ echo "ctrl_interface=/run/wpa_supplicant"; wpa_passphrase "$1" "$2" | grep -v '#psk=' | sed 's/}/    scan_ssid=1\n}/'; } \
    > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
mkdir -p /etc/systemd/system/wpa_supplicant@wlan0.service.d
cp "$here/restart.conf" /etc/systemd/system/wpa_supplicant@wlan0.service.d/
cp "$here/wlan0-dhcp.service" "$here/wlan0-event.service" /etc/systemd/system/
install -m 755 "$here/wlan0-event.sh" /usr/local/sbin/
f=/etc/network/interfaces.d/wlan0
[ -f "$f" ] && sed -i '/^auto wlan0$/d; /^allow-hotplug wlan0$/d' "$f"   # ifupdown must not bring wlan0 up as well
systemctl daemon-reload
systemctl enable --now wpa_supplicant@wlan0 wlan0-dhcp wlan0-event
echo "wlan0: $(ip -br addr show wlan0)"
