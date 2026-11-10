#!/bin/bash
# run.sh [options]: builds the Triangle Engine's bench in WSL (~/build_m2/te) and runs it; options as tb_te.cpp. NOBUILD=1 reuses the build.
# PROF=1: clocks per state, its own build.
set -e
R=${R:-/mnt/c/repos/konamim2-mister/mister}
B=${B:-~/build_m2/te}
if [ -n "$PROF" ]; then B=~/build_m2/te_prof; VFLAGS=--public-flat-rw; CF=-DTE_PROF; fi
# ZSDRAM=1: the Z buffer in SDRAM (the core's Z_SDRAM), its own build; ZLAT, ZBEAT, ZWR (tb_te.cpp) its timing
if [ -n "$ZSDRAM" ]; then B=${B}_z; VFLAGS="$VFLAGS +define+Z_SDRAM"; CF="$CF -DZ_SDRAM"; fi
VFLAGS="$VFLAGS +define+TE_COMPRESSED"   # (compressed TEXLOADs, a build option in the core: Battle Tryst's captures need them)
mkdir -p $B
export PATH=~/tools/oss-cad-suite/bin:$PATH
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module m2_te -Mdir $B -o tb_te \
  $VFLAGS -CFLAGS "-O2 -std=c++17 $CF" \
  $R/rtl/ppc_regs.sv $R/rtl/ppc_cache.sv $R/rtl/m2_te.sv $R/rtl/m2_zmem.sv \
  $R/sim/te/tb_te.cpp > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
fi
$B/tb_te "$@"
