#!/bin/bash
# run_cdda.sh: builds the CD audio's bench in WSL (~/build_m2/cdda) and runs it.
set -e
R=/mnt/c/repos/konamim2-mister/mister
B=${B:-~/build_m2/cdda}
mkdir -p $B
export PATH=~/tools/oss-cad-suite/bin:$PATH
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module m2_cdda -GLBA0=150 --prefix Vm2_cdda -Mdir $B -o tb_cdda \
  -CFLAGS "-O2 -std=c++17" $R/rtl/ppc_regs.sv $R/rtl/m2_cdda.sv $R/sim/dspp/tb_cdda.cpp > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
$B/tb_cdda "$@"
