#!/bin/bash
# Read-only Mali-400 / lima probe. Run on the board:  bash probe.sh
# from a PC (any shell, no quoting issues):           ssh <target> 'bash -s' < probe.sh
echo "kernel: $(uname -r)"; echo "kernel built with: $(grep -o 'gcc[^,]*' /proc/version | head -1)"
echo "--- render nodes (driver) ---"
for d in /sys/class/drm/renderD*; do echo "$d -> $(basename "$(readlink -f "$d/device/driver")")"; done
echo "--- kernel config ---"
{ zcat /proc/config.gz 2>/dev/null || cat "/boot/config-$(uname -r)" 2>/dev/null; } | grep -E 'CONFIG_DRM_LIMA[ =]|CONFIG_DRM_GEM_SHMEM_HELPER[ =]|CONFIG_MODULE_SIG_FORCE' || echo "(no config available)"
echo "--- loaded modules ---"; lsmod | grep -E '^(lima|gpu_sched|drm_shmem_helper) ' || echo "(none)"
echo "--- device tree ---"
G=$(dirname "$(grep -l 'arm,mali-400' /proc/device-tree/*/gpu*/compatible /proc/device-tree/gpu*/compatible 2>/dev/null | head -1)" 2>/dev/null)
if [ -n "$G" ] && [ "$G" != "." ]; then
  echo "node: $G"
  for p in compatible interrupt-names clock-names status; do printf '%s: ' "$p"; tr '\0' ' ' < "$G/$p" 2>/dev/null; echo; done
else echo "no arm,mali-400 node"; fi
echo "--- user space ---"
for f in /usr/lib/aarch64-linux-gnu/dri/lima_dri.so /usr/lib/aarch64-linux-gnu/libgbm.so.1; do [ -e "$f" ] && echo "ok $f" || echo "MISSING $f"; done
python3 -c "import OpenGL, numpy; print('PyOpenGL', OpenGL.__version__, '/ numpy', numpy.__version__)" 2>&1 | tail -1
