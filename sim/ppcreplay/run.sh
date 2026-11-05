#!/bin/bash
# run.sh trace [options]: builds the reference 602's replay bench in WSL (~/build_m2/ppcreplay) and runs it on a MAME
# trace (tools/lua/ppc_trace.lua); options as tb_ppcreplay.cpp. The boot ROM is unpacked from work/roms/polystar.zip.
# RTL=1 builds it with the RTL core (rtl/ppc_core.sv) in lockstep with the model (~/build_m2/ppcreplay_rtl); with PIPE=1
# too, the pipeline (rtl/ppc_pipe.sv; ~/build_m2/ppcreplay_pipe).
set -e
R=/mnt/c/repos/konamim2-mister/mister
W=/mnt/c/repos/konamim2-mister/work
B=~/build_m2/ppcreplay
mkdir -p $B
if [ -n "$RTL" ]; then
	if [ -n "$PIPE" ]; then TOP=ppc_pipe; BR=~/build_m2/ppcreplay_pipe; DEF=-DPIPE; else TOP=ppc_core; BR=~/build_m2/ppcreplay_rtl; DEF=; fi
	mkdir -p $BR
	export PATH=~/tools/oss-cad-suite/bin:$PATH
	if [ -z "$NOBUILD" ]; then
	verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module $TOP -Mdir $BR -o tb_ppcreplay \
	  -CFLAGS "-O2 -std=c++17 -ffp-contract=off -frounding-math -DWITH_RTL $DEF" \
	  $R/rtl/ppc_fpu_pkg.sv $R/rtl/ppc_fpu.sv $R/rtl/ppc_fpp.sv $R/rtl/ppc_fpx.sv $R/rtl/ppc_regs.sv $R/rtl/$TOP.sv $R/sim/ppcreplay/tb_ppcreplay.cpp $R/tools/ref/ppc602/ppc602.cpp \
	  > $BR/build.log 2>&1 || { grep -E "%Error|error:" $BR/build.log | head -40; exit 1; }
	fi
	EXE=$BR/tb_ppcreplay
else
	if [ -z "$NOBUILD" ]; then
	g++ -O2 -std=c++17 -ffp-contract=off -frounding-math -o $B/tb_ppcreplay $R/sim/ppcreplay/tb_ppcreplay.cpp $R/tools/ref/ppc602/ppc602.cpp
	fi
	EXE=$B/tb_ppcreplay
fi
[ -f $B/623b01.8q ] || python3 -I -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extract(\"623b01.8q\", sys.argv[2])" $W/roms/polystar.zip $B
T=$1; shift
$EXE $T -rom $B/623b01.8q "$@"
