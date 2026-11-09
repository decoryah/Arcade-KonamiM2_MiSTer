#!/bin/bash
# run.sh [cases] [steps] [seed] [lat]: builds the PPC602 core bench in WSL (~/build_m2/ppccore) and runs random programs on
# the RTL core and on the reference model (tools/ref/ppc602). PIPE=1: the pipeline (rtl/ppc_pipe.sv; ~/build_m2/ppccore_pipe),
# with random memory delays if lat is 1.
set -e
R=/mnt/c/repos/konamim2-mister/mister
export PATH=~/tools/oss-cad-suite/bin:$PATH
# CACHE=1 too: with its caches (rtl/ppc_cache.sv; ~/build_m2/ppccore_cache).
EXTRA=
if [ -n "$CACHE" ]; then TOP=ppc_cached; B=~/build_m2/ppccore_cache; DEF="-DPIPE -DCACHE"; EXTRA="$R/rtl/ppc_pipe.sv $R/rtl/ppc_cache.sv $R/sim/ppccore/fp_noise.sv $R/sim/ppccore/ppc_cached.sv"
elif [ -n "$PIPE" ]; then TOP=ppc_pipe; B=~/build_m2/ppccore_pipe; DEF=-DPIPE; EXTRA=$R/rtl/ppc_pipe.sv; else TOP=ppc_core; B=~/build_m2/ppccore; DEF=; EXTRA=$R/rtl/ppc_core.sv; fi
mkdir -p $B
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module $TOP -Mdir $B \
  -CFLAGS "-O2 -std=c++17 -ffp-contract=off -frounding-math $DEF" \
  $R/rtl/ppc_fpu_pkg.sv $R/rtl/ppc_fpu.sv $R/rtl/ppc_fps.sv $R/rtl/ppc_fpx.sv $R/rtl/ppc_regs.sv $EXTRA $R/sim/ppccore/tb_ppccore.cpp $R/tools/ref/ppc602/ppc602.cpp \
  > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
fi
$B/V$TOP "$@"
