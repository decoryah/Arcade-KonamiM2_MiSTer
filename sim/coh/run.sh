#!/bin/bash
# run.sh [clocks] [seed]: builds sim/coh's bench in WSL (~/build_m2/coh) and runs it: two caches and the DMA on the bus, each
# watching the others' writes (tb_coh.cpp says what's checked). An odd seed has DDR3 busy and slow.
set -e
R=${RTLROOT:-/mnt/c/repos/konamim2-mister/mister}
B=${B:-~/build_m2/coh}
export PATH=~/tools/oss-cad-suite/bin:$PATH
# DEFS="PPC_DATA32": build options, in the RTL and in the bench; their own build folder
VD=; CD=; for d in $DEFS; do VD="$VD +define+$d"; CD="$CD -D$d"; B=${B}_$d; done
mkdir -p $B
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module coh_top $VD -Mdir $B -o tb_coh \
  -CFLAGS "-O2 -std=c++17$CD" \
  $R/rtl/ppc_cache.sv $R/rtl/ppc_regs.sv $R/rtl/m2_bus.sv $R/sim/coh/coh_top.sv $R/sim/coh/tb_coh.cpp > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
fi
$B/tb_coh "$@"
