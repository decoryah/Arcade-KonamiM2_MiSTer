#!/bin/bash
# run_replay.sh <log> [last frame]: builds the DSP's replay of MAME's log in WSL (~/build_m2/dsprp) and runs it.
set -e
R=/mnt/c/repos/konamim2-mister/mister
B=${B:-~/build_m2/dsprp}
mkdir -p $B
export PATH=~/tools/oss-cad-suite/bin:$PATH
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module m2_dspp --public-flat-rw -Mdir $B -o tb_replay \
  -CFLAGS "-O2 -std=c++17" \
  $R/rtl/ppc_regs.sv $R/rtl/m2_dspp.sv \
  $R/sim/dspp/tb_replay.cpp > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
$B/tb_replay "$@"
