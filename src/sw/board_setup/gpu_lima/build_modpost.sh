#!/bin/bash
# Build scripts/mod/modpost in a private copy of the kernel build tree WITHOUT the top-level kbuild prepare
# (that re-runs kconfig with the board's gcc 11 and rewrites the config of a kernel built with gcc 12).
set -e
B=$(readlink -f /lib/modules/$(uname -r)/build); C=/home/xilinx/claude/kbuild
cp -p $B/.config $C/.config; cp -p $B/include/config/auto.conf $C/include/config/auto.conf
cp -p $B/include/generated/autoconf.h $C/include/generated/autoconf.h; rm -f $C/include/config/auto.conf.cmd
cd $C/scripts/mod
gcc -O2 -o mk_elfconfig mk_elfconfig.c
gcc -c -o empty.o empty.c
./mk_elfconfig < empty.o > elfconfig.h
cd $C
gcc -nostdinc -I./arch/arm64/include -I./arch/arm64/include/generated -I./include -I./arch/arm64/include/uapi \
    -I./arch/arm64/include/generated/uapi -I./include/uapi -I./include/generated/uapi \
    -include ./include/linux/compiler-version.h -include ./include/linux/kconfig.h -include ./include/linux/compiler_types.h \
    -D__KERNEL__ -mlittle-endian -std=gnu11 -fno-PIE -mgeneral-regs-only -mabi=lp64 -O2 \
    -DKBUILD_MODNAME='"devicetable_offsets"' -S -o scripts/mod/devicetable-offsets.s scripts/mod/devicetable-offsets.c
( echo "#ifndef __DEVICETABLE_OFFSETS_H__"; echo "#define __DEVICETABLE_OFFSETS_H__";
  sed -ne 's:^[[:space:]]*\.ascii[[:space:]]*"\(.*\)".*:\1:; /^->/{s:->#\(.*\):/* \1 */:; s:^->\([^ ]*\) [\$#]*\([^ ]*\) \(.*\):#define \1 \2 /* \3 */:; s:->::; p;}' scripts/mod/devicetable-offsets.s
  echo "#endif" ) > scripts/mod/devicetable-offsets.h
gcc -O2 -I scripts/mod -o scripts/mod/modpost scripts/mod/modpost.c scripts/mod/file2alias.c scripts/mod/sumversion.c
ls -la scripts/mod/modpost scripts/basic/fixdep
cmp .config $B/.config && echo "copy config == system config (original)"
