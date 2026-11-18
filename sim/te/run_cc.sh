#!/bin/bash
# run_cc.sh [steps] [seed ...]: builds the colour cache's own bench in WSL (~/build_m2/te_cc) and runs it (tb_cc.cpp: te_cache
# against a plain memory, random spans), once for each seed (default 2000000 steps, seeds 1 2 3 4). NOBUILD=1 reuses the build.
set -e
R=${R:-/mnt/c/repos/konamim2-mister/mister}
B=${B:-~/build_m2/te_cc}
mkdir -p $B
export PATH=~/tools/oss-cad-suite/bin:$PATH
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module te_cache -Mdir $B -o tb_cc \
  +define+TE_COMPRESSED -CFLAGS "-O2 -std=c++17" \
  $R/rtl/ppc_regs.sv $R/rtl/ppc_cache.sv $R/rtl/m2_te.sv $R/rtl/m2_zmem.sv \
  $R/sim/te/tb_cc.cpp > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
fi
steps=${1:-2000000}
shift || true
fail=0
for s in ${@:-1 2 3 4}; do $B/tb_cc $steps $s || fail=1; done
exit $fail
