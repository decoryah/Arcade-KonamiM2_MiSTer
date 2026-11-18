#!/bin/bash
# run.sh: builds the M48T58's bench (tb_tk.cpp, rtl/m2_tk.sv with a second of 100 clocks) in WSL (~/build_m2/tk) and runs it
set -e
R=$(cd "$(dirname "$0")/../.." && pwd)
B=${B:-~/build_m2/tk}
mkdir -p $B
export PATH=~/tools/oss-cad-suite/bin:$PATH
verilator --cc --exe --build -O2 -Wno-fatal -Wno-lint -Wno-style -GHZ=100 --top-module m2_tk -Mdir $B -o tb_tk \
  $R/rtl/ppc_regs.sv $R/rtl/m2_tk.sv $R/sim/tk/tb_tk.cpp > $B/build.log 2>&1 || { tail -20 $B/build.log; exit 1; }
$B/tb_tk
