#!/bin/bash
# run.sh [tests] [seed]: the MPEG unit's control against the M2 emulator's (tb_mpeg.cpp), built in WSL (~/build_m2/mpeg). NOBUILD=1 reuses the build.
set -e
R=${R:-$(cd "$(dirname "$0")/../.." && pwd)}
B=${B:-~/build_m2/mpeg}
mkdir -p $B
export PATH=~/tools/oss-cad-suite/bin:$PATH
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module m2_mpeg -Mdir $B -o tb_mpeg \
  -CFLAGS "-O2 -std=c++17" $R/rtl/m2_mpeg.sv $R/sim/mpeg/tb_mpeg.cpp > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
fi
$B/tb_mpeg "$@"
