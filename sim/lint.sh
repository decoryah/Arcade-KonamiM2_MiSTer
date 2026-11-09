#!/bin/sh
# Verilator lint of the machine and the platform modules: sim/lint.sh [max lines]
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
lint() {
    m=$1; shift
    echo "--- $m"
    verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME --top-module $m "$@" 2>&1 | grep -E "^%(Error|Warning)" | head -${MAXL:-40}
}
MAXL=$1
lint m2_vtiming ../rtl/m2_vtiming.sv
lint ppc_core ../rtl/ppc_fpu_pkg.sv ../rtl/ppc_fpu.sv ../rtl/ppc_core.sv
lint ppc_pipe ../rtl/ppc_fpu_pkg.sv ../rtl/ppc_fpu.sv ../rtl/ppc_fps.sv ../rtl/ppc_fpx.sv ../rtl/ppc_regs.sv ../rtl/ppc_pipe.sv
lint m2_boot ../rtl/ppc_fpu_pkg.sv ../rtl/ppc_fpu.sv ../rtl/ppc_fps.sv ../rtl/ppc_fpx.sv ../rtl/ppc_regs.sv ../rtl/ppc_pipe.sv ../rtl/ppc_cache.sv ../rtl/m2_bus.sv ../rtl/m2_cde.sv ../rtl/m2_atapi.sv ../rtl/m2_te.sv ../rtl/m2_dspp.sv ../rtl/m2_cdda.sv ../rtl/m2_kio.sv ../rtl/m2_vdu.sv ../rtl/m2_bda.sv ../rtl/m2_boot.sv
