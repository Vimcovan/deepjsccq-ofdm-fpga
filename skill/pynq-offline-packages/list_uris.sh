#!/bin/bash
# On the board (no internet needed): print the .deb files apt would download for the given packages, using the
# board's own package index.  Output lines: '<url>' <file> <size> <HashType>:<hex>
#   bash list_uris.sh python3-pyqt5 python3-pyqtgraph > uris.txt
[ $# -gt 0 ] || { echo "usage: list_uris.sh <package>..." >&2; exit 2; }
grep -hE '^(PRETTY_NAME|UBUNTU_CODENAME|VERSION_CODENAME)=' /etc/os-release >&2; dpkg --print-architecture >&2
out=$(apt-get install --print-uris -y -qq "$@" 2>&1) || { echo "$out" >&2; exit 1; }
echo "$out" | grep "^'http" || echo "nothing to download (already installed?)" >&2
