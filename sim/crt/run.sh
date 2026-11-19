#!/bin/bash
# CRT Adjust's bench (tb_crt.sv) with Icarus Verilog, on both rasters (about 7 minutes); the last line says PASS on both rasters
# or FAIL. Extra arguments go to the runs (+sweep); run.sh limits: the bench without the H-Position's limits (+limits: where they
# are, for rtl/m2_crt.sv's table)
set -e
cd "$(dirname "$0")"
R=../..
mkdir -p build
DEF=
if [ "$1" = limits ]; then DEF=-DNOCLAMP; shift; set -- +limits "$@"; fi
iverilog -g2012 $DEF -o build/tb_crt -I $R/rtl tb_crt.sv $R/rtl/m2_crt.sv $R/rtl/m2_vtiming.sv $R/modules/crt-adjust/crt_adjust.sv
echo "== the TV raster (857 x 262)"
a=$(vvp -n build/tb_crt "$@" | grep -v 'finish called'); echo "$a"
echo "== Hell Night's raster (673 x 416)"
b=$(vvp -n build/tb_crt +arc "$@" | grep -v 'finish called'); echo "$b"
if [ $# -eq 0 ]; then
	if echo "$a" | grep -q '^PASS' && echo "$b" | grep -q '^PASS'; then echo "PASS on both rasters"; else echo "FAIL"; fi
fi
