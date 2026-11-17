#!/bin/bash
# run_dcbz.sh [runs] [seed] [lat]: builds tb_dcbz.cpp (dcbz on the pipeline with its caches, every load of the zeroed line; see its
# header) in WSL (~/build_m2/dcbz) and runs it. R: the checkout (default the main one). DEFS="PPC_NO_FPDOUBLE PPC_DATA32 ...": a
# build's options in the RTL, its own build folder
set -e
R=${R:-/mnt/c/repos/konamim2-mister/mister}
B=~/build_m2/dcbz
export PATH=~/tools/oss-cad-suite/bin:$PATH
VD=; for d in $DEFS; do VD="$VD +define+$d"; B=${B}_${d#PPC_NO_}; done
mkdir -p $B
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module ppc_cached $VD -Mdir $B \
  -CFLAGS "-O2 -std=c++17 -DPIPE -DCACHE" \
  $R/rtl/ppc_fpu_pkg.sv $R/rtl/ppc_fpu.sv $R/rtl/ppc_fps.sv $R/rtl/ppc_fpx.sv $R/rtl/ppc_regs.sv $R/rtl/ppc_pipe.sv $R/rtl/ppc_cache.sv \
  $R/sim/ppccore/fp_noise.sv $R/sim/ppccore/ppc_cached.sv $R/sim/ppccore/tb_dcbz.cpp > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
fi
$B/Vppc_cached "$@"
