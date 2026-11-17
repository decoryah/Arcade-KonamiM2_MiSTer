#!/bin/bash
# run_hps.sh FILE... [options]: the MPEG unit built with MPEG_HPS and the ARM's decoder (hps/m2mpegd: its own code) on the M2
# emulator's MPEG dumps (tb_mpeg_hps.cpp), built in WSL (~/build_m2/mpeg_hps). NOBUILD=1 reuses the build.
#   MPEGD: the decoder's source (default: hps/m2mpegd/src in this repo)
#   BEAT_LOG2 (default 14): the unit's count for the daemon every 2^14 clocks here, not the core's 2^20: the daemon leaves a core whose
#   count stands still for 200 ms of real time, and the bench's clocks are slower than the core's
set -e
R=${R:-$(cd "$(dirname "$0")/../.." && pwd)}
B=${B:-~/build_m2/mpeg_hps}
MPEGD=${MPEGD:-$R/hps/m2mpegd/src}
mkdir -p $B
export PATH=~/tools/oss-cad-suite/bin:$PATH
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH +define+MPEG_HPS -GBEAT_LOG2=${BEAT_LOG2:-14} --top-module m2_mpeg -Mdir $B -o tb_mpeg_hps \
  -CFLAGS "-O3 -std=c++17 -ffp-contract=off -DM2MPEGD_FAST -I$MPEGD" -LDFLAGS "-pthread" \
  $R/rtl/m2_mpeg.sv $R/sim/mpeg/tb_mpeg_hps.cpp $MPEGD/m2mpegd_core.cpp $MPEGD/m2mpeg_unit.cpp $MPEGD/3dom2_mpeg.cpp > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
fi
$B/tb_mpeg_hps "$@"
