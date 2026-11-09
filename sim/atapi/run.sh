#!/bin/bash
# run.sh [tests] [seed]: the CD drive's data sectors, from memory and streamed (tb_atapi.cpp), built in WSL (~/build_m2/atapi). NOBUILD=1 reuses the build.
set -e
R=${R:-$(cd "$(dirname "$0")/../.." && pwd)}
B=${B:-~/build_m2/atapi}
mkdir -p $B
export PATH=~/tools/oss-cad-suite/bin:$PATH
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module m2_atapi -Mdir $B -o tb_atapi \
  -CFLAGS "-O2 -std=c++17" $R/rtl/ppc_regs.sv $R/rtl/m2_atapi.sv $R/sim/atapi/tb_atapi.cpp > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
fi
$B/tb_atapi "$@"
