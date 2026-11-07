#!/bin/bash
# run.sh [ops]: the single-precision float units (rtl/ppc_fps.sv) against the host's floats: the pipeline, then the iterative unit
set -e
R=/mnt/c/repos/konamim2-mister/mister
export PATH=~/tools/oss-cad-suite/bin:$PATH
N=${1:-2000000}
for TOP in ppc_fps_dp ppc_fps_it; do
	B=~/build_m2/ppcfps_$TOP
	DEF=""
	if [ $TOP = ppc_fps_it ]; then DEF=-DIT; fi
	mkdir -p $B
	verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module $TOP -Mdir $B -o tb_fps \
	  -CFLAGS "-O2 -std=c++17 -ffp-contract=off -frounding-math $DEF" \
	  $R/rtl/ppc_fpu_pkg.sv $R/rtl/ppc_fps.sv $R/sim/ppcfps/tb_fps.cpp > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -30; exit 1; }
	echo "--- $TOP"
	$B/tb_fps $N
done
