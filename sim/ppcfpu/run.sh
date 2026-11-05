#!/bin/bash
# run.sh [count] [seed]: builds the PPC602 float unit bench in WSL (~/build_m2/ppcfpu) and runs random operations on the
# RTL unit and on the reference model (tools/ref/ppc602). FPP=1: the float pipeline (rtl/ppc_fpp.sv) instead
# (~/build_m2/ppcfpu_fpp).
set -e
R=/mnt/c/repos/konamim2-mister/mister
B=~/build_m2/ppcfpu
TOP=ppc_fpu
DEF=
if [ -n "$FPP" ]; then B=~/build_m2/ppcfpu_fpp; TOP=ppc_fpp; DEF=-DFPP; fi
mkdir -p $B
export PATH=~/tools/oss-cad-suite/bin:$PATH
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module $TOP -Mdir $B \
  -CFLAGS "-O2 -std=c++17 -ffp-contract=off -frounding-math $DEF" \
  $R/rtl/ppc_fpu_pkg.sv $R/rtl/$TOP.sv $R/sim/ppcfpu/tb_ppcfpu.cpp $R/tools/ref/ppc602/ppc602.cpp \
  > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
fi
$B/V$TOP "$@"
