---
name: pynq-offline-packages
description: Install Ubuntu packages (apt .deb) or Python wheels on a PYNQ board (or any Ubuntu-based Zynq / embedded ARM board) that has no internet access, by resolving the exact files on the board, downloading them on a PC, verifying checksums and installing offline — and make them visible inside the PYNQ virtual environment. Use when `apt install` / `pip install` on the board fails with network errors, when the user says the board is offline / only connected to the PC by USB or Ethernet, or asks how to get a library (PyQt5, OpenCV, PyOpenGL, ...) onto the board.
argument-hint: "[package names] [ssh-target]"
---

# Offline apt / pip Installs for PYNQ

## Purpose

Get packages onto a board that cannot reach the Ubuntu mirrors or PyPI, with exactly the versions the board's own
package database expects, and without guessing dependencies.

**Expected outcome:** a verified set of `.deb` files (or wheels) on the PC, installed on the board, and an import /
version check run with the interpreter the user's program actually uses (usually the PYNQ venv).

**Prerequisites:**
- Shell on the board (root for apt); a PC with internet that can copy files to the board (`scp`, USB drive)
- Python 3 on the PC (for `fetch_debs.py`, `pip download`)

---

## When to Use

- `apt install` / `pip install` on the board fails (no DNS, no route, proxy)
- A program needs a library that is not in the PYNQ image (GUI toolkits, OpenGL bindings, codecs, tools)
- The user wants a reproducible offline bundle for several boards

## When NOT to Use

- The board has internet → plain `apt install` / `pip install`
- The package is not in Ubuntu or on PyPI for `aarch64` → it must be built on the board

---

## DO's

- **Track every file you copy to the board and delete it whenever you stop** — before the summary, at a USER GATE, and
  before any clarifying question (scripts, copies of the user's program, screenshots, error logs in `/tmp`)
- Stay inside the workspace and the board paths the user named; do not search other directories on the PC for the user's files — ask
- **Resolve on the board**: let the board's apt compute the file list from its own index (`list_uris.sh`); it
  knows what is already installed and pins the versions that match the image
- Prefer **apt** for anything with native libraries (Qt, OpenGL, GStreamer, OpenCV with GUI); use **pip wheels**
  for pure-Python packages or packages not in Ubuntu
- Verify every downloaded file (size + checksum) before copying it to the board
- After installing, check the import **in the PYNQ venv** and print the module path
- **Compare versions before choosing apt or pip**: the image's apt index is frozen at its release (PYNQ 3.x: Ubuntu
  22.04, 2022), PyPI has newer releases, and major versions can break the API (e.g. `python3-paho-mqtt` 1.5.1 from apt
  vs `paho-mqtt` 2.x from PyPI, where `mqtt.Client()` needs a `CallbackAPIVersion` argument). If the user's code is
  available, check which API it uses; otherwise present both versions and let the user choose

## DON'Ts

- **Never kill processes by name** on the PC or the board (`Stop-Process -Name ssh`, `Get-Process ssh | Stop-Process`, `pkill ssh`, `killall python3`) — other sessions use them; stop only a process you started, by its exact PID
- **Copy commands name the remote side explicitly**: `scp <local file> <target>:<remote dir>/` and `scp <target>:<remote file> <local dir>/`; never pass a local credential (the `-i` key, anything under `~/.ssh`) as a source or destination, and never write into `~/.ssh`
- **Never guess package lists or download "latest" versions from packages.ubuntu.com by hand** — versions must match the board's index
- **Never pipe a script through PowerShell into ssh** (`Get-Content x | ssh`) — PowerShell prepends a BOM; copy files with `scp` and run them
- **Never install into the system without the user's go-ahead** (USER GATE 1)
- Do not `pip install` a package that apt already provides into the venv — the venv copy shadows the system one and may not match its native libraries
- Do not run `apt-get update` on an offline board expecting it to help — it only fails and may leave partial lists

> **Why resolve on the board:** `python3-pyqt5` + `python3-pyqtgraph` alone pulled in 35 files on a stock PYNQ-ZU
> image (Qt libraries, xcb plugins, fonts, PyOpenGL). Listing them by hand from package web pages misses some and picks
> versions that do not match the image; `apt-get install --print-uris` on the board gives the complete, matching set.

---

## Workflow

> USER GATE questions below are templates: ask them in the user's language, and stop until the user answers.
> **No answer is not a yes**: if a question tool returns "skipped", times out, or the session is non-interactive, treat
> it as NO — end the turn with the question and a summary instead of choosing for the user.

```
Task Progress:
- [ ] Step 1: Probe board (OS, arch, Python, venv, network)
- [ ] Step 2: Resolve file list on the board
- [ ] Step 3: Download + verify on the PC
- [ ] USER GATE 1: install
- [ ] Step 4: Copy + install on the board
- [ ] Step 5: Verify in the venv
- [ ] Step 6: Clean up + summary
```

### Step 1 — Probe

```bash
grep -E '^(PRETTY_NAME|UBUNTU_CODENAME)=' /etc/os-release; dpkg --print-architecture
cat /etc/profile.d/pynq_venv.sh 2>/dev/null          # PYNQ: 'source /usr/local/share/pynq-venv/bin/activate'
grep include-system-site-packages /usr/local/share/pynq-venv/pyvenv.cfg 2>/dev/null
source /etc/profile.d/pynq_venv.sh 2>/dev/null; python3 --version; pip --version
ls -la /var/lib/apt/lists/*Packages* | head          # does the board have a package index, and how old?
```

Record: Ubuntu codename (PYNQ 3.x → `jammy`), arch (`arm64`), Python version (PYNQ 3.x → 3.10), whether the venv
sees system packages (`include-system-site-packages = true` → apt-installed `python3-*` modules are importable in the venv).

### Step 2 — Resolve (apt)

Copy `list_uris.sh` to the board and run it with the package names:

```bash
scp list_uris.sh <target>:/tmp/ ; ssh <target> bash /tmp/list_uris.sh python3-pyqt5 python3-pyqtgraph > uris.txt
```

Each line: `'<url>' <file> <size> <HashType>:<hex>`. Empty output = already installed.
If apt reports `Unable to locate package`: the name is wrong or the index lacks that component (see "Index problems").

**pip instead:** skip to Step 3b.

### Step 3 — Download and verify on the PC

```bash
python fetch_debs.py uris.txt debs/          # downloads, checks size + checksum, exit code 1 on any failure
```

VERIFY: last line `N/N files ok`. A `404` → "Index problems" below.

### Step 3b — pip wheels on the PC

Use the board's Python version and `aarch64` wheels; binary only (no source builds on the PC):

```bash
pip download --only-binary=:all: --platform manylinux2014_aarch64 --python-version 3.10 \
    --implementation cp --abi cp310 -d wheels <package>
```

`manylinux_2_28` wheels need glibc ≥ 2.28 (`ldd --version` on the board; PYNQ 3.x has 2.35). If pip finds no wheel,
the package needs compiling on the board — report it and stop.

### USER GATE 1 — Install

Present the file list (count, total size) and ask:
**"Install these N packages on the board? apt packages go into the system; wheels go into the PYNQ venv."**

### Step 4 — Copy and install

```bash
ssh <target> mkdir -p /tmp/offline_pkgs
scp debs/*.deb install_debs.sh <target>:/tmp/offline_pkgs/
ssh <target> bash /tmp/offline_pkgs/install_debs.sh /tmp/offline_pkgs --dry-run   # optional preview
ssh <target> bash /tmp/offline_pkgs/install_debs.sh /tmp/offline_pkgs
```

`install_debs.sh` runs `dpkg -i` on all files, then `apt-get -f install --no-download` to finish configuration
order, and checks every package is `install ok installed`.

Wheels (inside the venv): `source /etc/profile.d/pynq_venv.sh && pip install --no-index --find-links /tmp/offline_pkgs/wheels <package>`

### Step 5 — Verify

Run with the interpreter the program uses (on PYNQ: the venv, also under `sudo` / systemd):

```bash
source /etc/profile.d/pynq_venv.sh
python3 -c "import <module>; print(<module>.__version__ if hasattr(<module>,'__version__') else 'ok', <module>.__file__)"
```

VERIFY: imports work; the path is `/usr/lib/python3/dist-packages/...` for apt packages or the venv's
`site-packages` for wheels — not an unexpected older copy elsewhere.

### Step 6 — Clean up and summarize

Delete everything copied to the board, including when you stop at a USER GATE: `ssh <target> rm -rf /tmp/list_uris.sh /tmp/offline_pkgs`.


| Item | Result |
|---|---|
| Board | Ubuntu codename, arch, Python |
| Method | apt / pip |
| Files | count, total size, all checksums ok |
| Installed | package list, `dpkg` status |
| Import check | module, version, path |
| Leftovers on the board | none (list what was removed); `debs/` kept on the PC for other boards |

---

## Index problems

These fixes follow from how apt works; they were not needed on the reference board (its index is the release pocket only).

| Symptom | Cause | Fix |
|---|---|---|
| `fetch_debs.py` gets 404 | board index lists a version the mirror removed (an `-updates` / `-security` version superseded since the image was built) | download the current `Packages.xz` for that pocket on the PC, or pick the release-pocket version: `apt-get install <pkg>=<version>`; release-pocket files (`jammy` itself) are never removed |
| `Unable to locate package` | index missing for `universe` / that component, or no index at all | copy matching `dists/<codename>/<component>/binary-arm64/Packages.xz` into `/var/lib/apt/lists/` with apt's file naming, or ask the user to connect the board once |
| `dpkg` complains about a missing dependency that is not in the list | file list resolved on another board / older state | re-run Step 2 on this board |

## Reference

PYNQ-ZU, PynqLinux 3.0 based on Ubuntu 22.04 (`jammy`, arm64), Python 3.10.4, pip 22.0.2, glibc 2.35; the image ships
the `jammy` release-pocket index for `main` and `universe` (2022), and the venv has `include-system-site-packages = true`.
PyQt5 5.15.6 + pyqtgraph 0.12.4 + PyOpenGL 3.1.5 (35 files, ≈ 20 MB) were installed this way; all checksums matched the
board's index and the modules import in the venv.

## Files

| File | Where it runs | Purpose |
|---|---|---|
| `list_uris.sh <pkg>...` | board | apt's download list for the packages (URL, file, size, checksum) |
| `fetch_debs.py <uris.txt> <dir>` | PC | download + verify size and checksum |
| `install_debs.sh <dir> [--dry-run]` | board, root | offline install and per-package status check |
