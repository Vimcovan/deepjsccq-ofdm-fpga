"""Restore the kernel build tree's generated config after an aborted `make modules_prepare` (board gcc 11 re-ran
syncconfig): .config <- .config.old (original), and regenerate include/config/auto.conf + include/generated/autoconf.h
from it in kconfig's format (confdata.c, Linux 6.6)."""
import os, re, shutil, sys
B = sys.argv[1]
cfg = open(os.path.join(B, ".config.old")).read().splitlines()
if 'CONFIG_CC_VERSION_TEXT="gcc (GCC) 12.2.0"' not in cfg:
    sys.exit("unexpected .config.old")
if open(os.path.join(B, ".config")).read() != open(os.path.join(B, ".config.old")).read():
    shutil.copy2(os.path.join(B, ".config.old"), os.path.join(B, ".config"))
ver = next(l for l in open(os.path.join(B, ".config.old")) if "Kernel Configuration" in l).strip("# \n")
ac = ["#", "# Automatically generated file; DO NOT EDIT.", f"# {ver}", "#"]
ah = ["/*", " * Automatically generated file; DO NOT EDIT.", f" * {ver}", " */"]
for l in cfg:
    m = re.match(r"^(CONFIG_\w+)=(.*)$", l)
    if not m:
        continue
    k, v = m.groups()
    # auto.conf (since Linux 5.18): string values unquoted and unescaped; autoconf.h keeps the C string literal
    ac.append(f"{k}={v[1:-1].replace(chr(92) + chr(34), chr(34)).replace(chr(92) * 2, chr(92))}" if v.startswith('"') else l)
    if v == "y":   ah.append(f"#define {k} 1")
    elif v == "m": ah.append(f"#define {k}_MODULE 1")
    elif v == "n": continue
    else:          ah.append(f"#define {k} {v}")
open(os.path.join(B, "include/config/auto.conf"), "w").write("\n".join(ac) + "\n")
open(os.path.join(B, "include/generated/autoconf.h"), "w").write("\n".join(ah) + "\n")
cmd = os.path.join(B, "include/config/auto.conf.cmd")
s = open(cmd).read().replace("gcc (Ubuntu 11.2.0-19ubuntu1) 11.2.0", "gcc (GCC) 12.2.0")
open(cmd, "w").write(s)
print("restored:", len(ac) - 4, "symbols")
