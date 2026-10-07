#!/bin/bash
# Offline install of PyQt5 5.15 / pyqtgraph / PyOpenGL for the RX board GUI (Ubuntu 22.04 arm64 packages, PYNQ image
# without network access to the Ubuntu mirrors): download the packages listed in urls.txt on a PC, copy them with this
# script to the board, then as root:   bash install.sh <dir with the .deb files>
set -e
cd "${1:-.}"
dpkg -i ./*.deb || apt-get -f install -y      # second call resolves ordering between the packages
python3 -c "import PyQt5.QtCore, pyqtgraph; print('PyQt5', PyQt5.QtCore.PYQT_VERSION_STR, 'pyqtgraph', pyqtgraph.__version__)"
