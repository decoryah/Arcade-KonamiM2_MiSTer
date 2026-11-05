#!/bin/bash
# run.sh [programs] [instructions each]: builds the DSP's bench in WSL (~/build_m2/dspp) and runs it. NOBUILD=1 reuses the build.
set -e
R=/mnt/c/repos/konamim2-mister/mister
B=${B:-~/build_m2/dspp}
mkdir -p $B
export PATH=~/tools/oss-cad-suite/bin:$PATH
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module m2_dspp -GFROZEN=1 --public-flat-rw -Mdir $B -o tb_dspp \
  -CFLAGS "-O2 -std=c++17" \
  $R/rtl/ppc_regs.sv $R/rtl/m2_dspp.sv \
  $R/sim/dspp/tb_dspp.cpp > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
fi
$B/tb_dspp "$@"
