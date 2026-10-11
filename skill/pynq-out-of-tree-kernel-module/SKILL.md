---
name: pynq-out-of-tree-kernel-module
description: Build a Linux driver that exists in the kernel source but is not enabled in the image's kernel config (e.g. lima GPU, hid-multitouch, a USB network or serial driver) as a loadable external module directly on a PYNQ / Zynq / Zynq UltraScale+ board, without rebuilding or replacing the kernel. Use when the user needs a missing kernel driver on the board, when `CONFIG_<X> is not set` blocks a device, or when an external-module build fails because the board's gcc differs from the gcc that built the kernel.
argument-hint: "[CONFIG symbol or driver name] [ssh-target]"
---

# External Kernel Modules on PYNQ (no kernel rebuild)

## Purpose

Produce `.ko` files for a driver that the running kernel was built without, using the board's own compiler and the
installed kernel build tree, then load them safely.

**Expected outcome:** the module(s) built in a private directory, `vermagic` matching `uname -r`, a temporary load
verified in `dmesg`, and — only on request — persistent loading with an undo command.

**Prerequisites:**
- Root shell on the board; `/lib/modules/$(uname -r)/build` exists (kernel headers / build tree), `gcc`, `make`
- The driver source of the **same kernel version** (downloaded on a PC if the board has no internet)
- Hardware description present (device-tree node, USB IDs) — a module does not create missing hardware nodes

---

## When to Use

- `zcat /proc/config.gz | grep CONFIG_<X>` prints `is not set` and the device needs that driver
- `make -C /lib/modules/$(uname -r)/build M=...` fails with unknown gcc options or rewrites the kernel config
- The user wants to try a driver without touching the boot image (`BOOT.BIN`, `image.ub`)

## When NOT to Use

- The option is `bool`-only (cannot be `=m`, e.g. core architecture features) → requires a kernel rebuild
- Module signing is enforced (`CONFIG_MODULE_SIG_FORCE=y`) → unsigned modules will not load
- A distribution package with the module exists for this exact kernel → install it instead

---

## DO's

- **Track every file you put on the board.** Scratch files go whenever you stop (summary, USER GATE, clarifying question); the work directory `$W` (tree copy +
  module) stays for loading and is reported with its size and a removal command
- Map `uname -r` to the exact source tag first (Xilinx kernels: `Xilinx/linux-xlnx`, e.g. `6.6.10-xilinx-v2024.1` → tag `xlnx_rebase_v6.6_LTS_2024.1`)
- Resolve dependencies from the driver's `Kconfig` (`select`, `depends on`) and check each one in `/proc/config.gz`
- Put the driver **and every missing dependency** in one `M=` project so `modpost` resolves their exported symbols
- Work in a **private copy** of the build tree when the compilers differ
- Check `vermagic` before loading; load temporarily first
- Use **one work directory per driver on the board**, e.g. `/root/oot/<driver>/` holding `kbuild/` (private tree copy)
  and `src/`; keep PC downloads inside the workspace (`./<driver>-src/`), not in system temp directories
- Quote remote commands with **single quotes** (`ssh <target> '... $(uname -r) ...'`) — PowerShell and bash expand
  `$` inside double quotes on the PC side

## DON'Ts

- **Never reboot or power-cycle the board yourself** — ask the user; a reboot interrupts whatever else runs on it
- **Never try passwords or default credentials** (ssh, Jupyter, web UIs) — if access fails, stop and report
- **Never kill processes by name** on the PC or the board (`Stop-Process -Name ssh`, `Get-Process ssh | Stop-Process`, `pkill ssh`, `killall python3`) — other sessions use them; stop only a process you started, by its exact PID
- **Copy commands name the remote side explicitly**: `scp <local file> <target>:<remote dir>/` and `scp <target>:<remote file> <local dir>/`; never pass a local credential (the `-i` key, anything under `~/.ssh`) as a source or destination, and never write into `~/.ssh`
- **Never run `make modules_prepare` / `make prepare` / `make olddefconfig` in `/lib/modules/$(uname -r)/build`** —
  with a different gcc it re-runs kconfig, rewrites `.config` and deletes `include/generated/autoconf.h`
- **Never edit or delete files in the system build tree**; copy it
- **Never write `/lib/modules/.../extra` or `/etc/modules-load.d` without the user's go-ahead** (USER GATE 2)
- Stay inside the workspace and the board paths the user named; do not search other directories on the PC — ask
- Do not write anything on the PC outside the workspace (no `%TEMP%` / `/tmp` staging directories)
- Do not "fix" gcc errors by editing kernel headers — filter the offending flag in the compiler wrapper
- **Never `rm -rf` a directory you did not create in this session** (e.g. an existing `~/kbuild` may be another
  driver's tree) — pick a new path or ask

> **Anti-pattern:** the agent ran `make modules_prepare` in the system build tree. Kernel built with gcc 12.2.0,
> board gcc 11.2.0, board clock in the past → kconfig ran again, `.config` was rewritten and `autoconf.h` deleted.
> The running kernel was unaffected, but every later module build would have used the wrong config. Recovery:
> restore `.config` from `.config.old` and regenerate `include/config/auto.conf` and `include/generated/autoconf.h`.

---

## Workflow

> USER GATE questions below are templates: ask them in the user's language, and stop until the user answers.
> **No answer is not a yes**: if a question tool returns "skipped", times out, or the session is non-interactive, treat
> it as NO — end the turn with the question and a summary instead of choosing for the user.
> **Explicit, low-risk requests need no GATE**: if the user already asked for exactly this action and it is easy to
> undo and changes nothing system-wide (copy files into a scratch directory, install a pure-Python package for the
> user's program, apply the fix the user asked for to the user's own file), do it and report what changed and how
> to undo it. Keep the GATE even after an explicit request for: loading kernel modules, installing / enabling /
> stopping / restarting services, rebooting, changing system configuration or system packages, anything that can
> take down the running application or the display, and editing code when the user only asked for a check.

```
Task Progress:
- [ ] Step 1: Probe kernel, compiler, config
- [ ] Step 2: Collect sources + write Kbuild files
- [ ] Step 3: Prepare private build tree
- [ ] Step 4: Build + check vermagic
- [ ] USER GATE 1: temporary load
- [ ] Step 5: Load + verify
- [ ] USER GATE 2: persistent load
- [ ] Step 6: Summary
```

### Step 1 — Probe

```bash
uname -r; cat /proc/version            # gcc that built the kernel
gcc --version | head -1                # gcc on the board
zcat /proc/config.gz | grep -E 'CONFIG_<X>|CONFIG_MODULE_SIG'
B=$(readlink -f /lib/modules/$(uname -r)/build); ls $B/.config $B/Module.symvers $B/scripts/basic/fixdep
date                                   # fix the clock (NTP / date -s) if it is in the past
```

Record: kernel gcc version, board gcc version, whether they differ, and the list of missing `CONFIG_` symbols.

### Step 2 — Sources and Kbuild

Create the board work directory first (fails if it exists → choose another path or ask):
`ssh <target> 'W=/root/oot/<driver>; mkdir -p /root/oot && mkdir $W && mkdir $W/src'`

Fetch only the needed files from the matching tag on the PC, one file per request:
`https://raw.githubusercontent.com/<org>/<repo>/<tag>/<path>` (e.g. `Xilinx/linux-xlnx/xlnx_rebase_v6.6_LTS_2024.1/drivers/hid/hid-multitouch.c`).
To list a directory's files: `https://api.github.com/repos/<org>/<repo>/contents/<dir>?ref=<tag>` (unauthenticated: 60 requests per hour per IP — list once, then fetch files from `raw.githubusercontent.com`, which is not rate-limited this way).
Do not clone the kernel repository on Windows — even a sparse checkout fails on reserved file names such as `aux.c`.
Then copy sources, `Kbuild`/`Makefile` and this skill's scripts **straight into `$W/src`** (`scp ... <target>:$W/src/`),
not into a staging directory in `/tmp`. Examples of what to fetch, for lima:
`drivers/gpu/drm/lima/`, `drivers/gpu/drm/scheduler/`, `drivers/gpu/drm/drm_gem_shmem_helper.c`.
Public headers (`include/...`) are already in the build tree; copy private headers that sit next to the `.c` files.

The upstream Makefiles use `obj-$(CONFIG_X)`, which is undefined here. Write one `Kbuild` per directory and one top Makefile:

```make
# top-level Makefile — dependencies first, all in one M= project
obj-m += scheduler/ shmem/ lima/
KDIR ?= /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
```

```make
# <dir>/Kbuild — module name and object list copied from the upstream Makefile
obj-m := lima.o
lima-y := lima_drv.o lima_device.o lima_pmu.o lima_l2_cache.o lima_mmu.o lima_gp.o lima_pp.o lima_gem.o lima_vm.o lima_sched.o lima_ctx.o lima_dlbu.o lima_bcast.o lima_trace.o lima_devfreq.o
ccflags-y += -I$(src)
```

If the board gcc **equals** the kernel gcc: skip the private tree copy in Step 3, build in `$W/src` with `make`.

### Step 3 — Private build tree (compilers differ)

```bash
W=/root/oot/<driver>                                                 # created in Step 2
cp -a "$(readlink -f /lib/modules/$(uname -r)/build)" $W/kbuild      # ~100 MB
bash gen_arch_headers.sh $W/kbuild     # arch/arm64/include/generated/* without the top-level Makefile
bash build_modpost.sh $W/kbuild        # scripts/mod/modpost with the board gcc; restores the original config
```

VERIFY: `build_modpost.sh` ends with `copy config == system config (original)`; `cpucaps.h` and `sysreg-defs.h` are listed.

### Step 4 — Build

```bash
cd $W/src && make KDIR=$W/kbuild CC=$W/src/gcc-wrap   # gcc-wrap drops -ftrivial-auto-var-init=zero (gcc 12 only)
modinfo -F vermagic */*.ko; uname -r
```

If gcc reports another unknown option, add it to the filter in `gcc-wrap` — do not change kernel files.
VERIFY: every `vermagic` starts with the exact `uname -r` string.

### USER GATE 1 — Temporary load

Ask (fill in the numbers):
**"Modules built: `<files>`, vermagic matches. Left on the board: `$W` (`<du -sh>`, needed for loading; remove with
`rm -rf $W`). Load them now (temporary, undone by reboot)? A faulty driver can hang the board and need a power cycle."**

### Step 5 — Load and verify

```bash
insmod <dependency>.ko ... && insmod <driver>.ko      # dependencies first
dmesg | tail -30; lsmod | head
```

VERIFY: the driver probes the device (driver-specific message, new `/dev` node). On failure report `dmesg` and stop.

### USER GATE 2 — Persistent load

Ask: **"Load at every boot?"** On yes:

```bash
mkdir -p /lib/modules/$(uname -r)/extra && cp *.ko /lib/modules/$(uname -r)/extra/ && depmod -a
echo <driver> > /etc/modules-load.d/<driver>.conf     # modprobe resolves the dependency order
# undo: rm /etc/modules-load.d/<driver>.conf /lib/modules/$(uname -r)/extra/<each>.ko && depmod -a
```

### Step 6 — Summary

| Item | Result |
|---|---|
| Kernel / kernel gcc / board gcc | |
| Source tag and directories | |
| Modules built | name, size |
| vermagic | matches `uname -r`: yes / no |
| Load result | `dmesg` key lines |
| System files changed | list + undo command (normally none before USER GATE 2) |
| Left on the board | `$W` with size (`du -sh`); kept for loading / rebuilding; remove with `rm -rf $W` |
| Left on the PC | downloaded sources in the workspace |

Remind the user: the modules work only with this kernel; after an image update they must be rebuilt.

---

## Reference

Tested on PYNQ-ZU: PynqLinux (Ubuntu 22.04), kernel `6.6.10-xilinx-v2024.1` built with gcc 12.2.0, board gcc 11.2.0.
`lima` + `gpu-sched` + `drm_shmem_helper` from a fresh build-tree copy: Steps 3–4 take about 1 minute; the system
build tree's `.config` is byte-identical before and after.

## Files

| File | Purpose |
|---|---|
| `gen_arch_headers.sh <tree>` | Generates `arch/arm64/include/generated/{asm,uapi/asm}`, `cpucaps.h`, `sysreg-defs.h` via sub-makefiles |
| `build_modpost.sh <tree>` | Copies the original config into the private tree, builds `scripts/mod/modpost` with the board gcc |
| `gcc-wrap` | Compiler wrapper that removes gcc-12-only flags |
