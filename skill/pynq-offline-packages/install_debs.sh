#!/bin/bash
# On the board, as root: install every .deb in a directory, offline.
#   bash install_debs.sh <dir>            install
#   bash install_debs.sh <dir> --dry-run  only show what dpkg would do
cd "${1:?usage: install_debs.sh <dir with .deb files> [--dry-run]}" || exit 1
ls ./*.deb >/dev/null || exit 1
if [ "$2" = "--dry-run" ]; then dpkg --dry-run -i ./*.deb; exit; fi
# dpkg installs in argument order; a package configured before its dependency fails once, and apt-get -f
# then configures it from what is already unpacked (--no-download: never reaches for the network)
dpkg -i ./*.deb || apt-get -f install -y --no-download
bad=0
for f in ./*.deb; do
  p=$(dpkg-deb -f "$f" Package)
  s=$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)
  [ "$s" = "install ok installed" ] || { echo "NOT INSTALLED: $p ($s)"; bad=1; }
done
[ $bad = 0 ] && echo "all packages installed"; exit $bad
