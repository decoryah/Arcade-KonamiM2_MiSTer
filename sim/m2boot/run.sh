#!/bin/bash
# run.sh [options]: builds the bring-up machine's bench in WSL (~/build_m2/m2boot) and runs it on the boot ROM against
# MAME's power-on trace; options as tb_m2boot.cpp. NOBUILD=1 reuses the build.
set -e
R=${R:-/mnt/c/repos/konamim2-mister/mister}
W=/mnt/c/repos/konamim2-mister/work
B=${B:-~/build_m2/m2boot}
mkdir -p $B
export PATH=~/tools/oss-cad-suite/bin:$PATH
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH --top-module m2_boot $VFLAGS -Mdir $B -o tb_m2boot \
  -CFLAGS "-O2 -std=c++17" \
  $R/rtl/ppc_fpu_pkg.sv $R/rtl/ppc_fpu.sv $R/rtl/ppc_fps.sv $R/rtl/ppc_fpx.sv $R/rtl/ppc_regs.sv $R/rtl/ppc_pipe.sv $R/rtl/ppc_cache.sv $R/rtl/m2_bus.sv $R/rtl/m2_cde.sv $R/rtl/m2_bda.sv $R/rtl/m2_atapi.sv $R/rtl/m2_kio.sv $R/rtl/m2_ymz280b.sv $R/rtl/m2_vdu.sv $R/rtl/m2_te.sv $R/rtl/m2_dspp.sv $R/rtl/m2_cdda.sv $R/rtl/m2_prof.sv $R/rtl/m2_boot.sv \
  $R/sim/m2boot/tb_m2boot.cpp > $B/build.log 2>&1 || { grep -E "%Error|error:" $B/build.log | head -40; exit 1; }
fi
[ -f $B/623b01.8q ] || python3 -I -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extract(\"623b01.8q\", sys.argv[2])" $W/roms/polystar.zip $B
[ -f $W/cap/boot/p1.pcs ] || python3 -I $W/scripts/trpcs.py $W/cap/boot/p1.tr $W/cap/boot/p1.pcs
$B/tb_m2boot $B/623b01.8q $W/cap/boot/p1.pcs "$@"
