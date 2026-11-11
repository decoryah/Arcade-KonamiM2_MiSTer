#!/bin/bash
# run.sh [seed] [ticks] [trace]: the YMZ280B (rtl/m2_ymz280b.sv) against tb_ymz.cpp's port of MAME's: a random run, and with a trace (work/cap/evil/ymz.trace)
# the game's own writes. NOBUILD=1 reuses the build.
set -e
R=${R:-/mnt/c/repos/konamim2-mister/mister}
W=/mnt/c/repos/konamim2-mister/work
B=${B:-~/build_m2/ymz}
mkdir -p $B
export PATH=~/tools/oss-cad-suite/bin:$PATH
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module m2_ymz280b -Mdir $B -o tb_ymz -CFLAGS "-O2 -std=c++17" \
  $R/rtl/m2_ymz280b.sv $R/sim/ymz/tb_ymz.cpp > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
fi
[ -f $B/810a03.16h ] || python3 -I -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extract(\"810a03.16h\", sys.argv[2])" $W/roms/evilngt.zip $B
$B/tb_ymz $B/810a03.16h "$@"
