#!/bin/bash
# Generate arch/arm64/include/generated/{asm,uapi/asm} (asm-generic wrappers, cpucaps.h, sysreg-defs.h) in the private
# build-tree copy by calling the sub-makefiles directly: the top-level Makefile would re-run kconfig with gcc 11.
set -e
C=/home/xilinx/claude/kbuild; cd $C
rm -rf arch/arm64/include/generated arch//include/generated arch/include/generated
export ARCH=arm64 SRCARCH=arm64 srctree=. objtree=. KBUILD_SRC= CONFIG_SHELL=/bin/sh AWK=awk Q= quiet=quiet_ KBUILD_VERBOSE=0
make -f scripts/Makefile.asm-generic obj=arch/arm64/include/generated/uapi/asm generic=include/uapi/asm-generic
make -f scripts/Makefile.asm-generic obj=arch/arm64/include/generated/asm generic=include/asm-generic
make -f scripts/Makefile.build obj=arch/arm64/tools kapi
ls arch/arm64/include/generated/asm | wc -l; ls arch/arm64/include/generated/uapi/asm | wc -l
ls arch/arm64/include/generated/asm/cpucaps.h arch/arm64/include/generated/asm/sysreg-defs.h
