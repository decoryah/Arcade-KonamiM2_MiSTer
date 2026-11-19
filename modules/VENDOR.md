# Vendored modules

Third-party HDL copied into the tree (no submodules, so the build is self-contained and reproducible). Each keeps its own licence
alongside.

| module | upstream | licence |
|---|---|---|
| crt-adjust | https://github.com/rmonic79/MiSTer-CRT-Adjust @ c682de9f4acc61d8f4c7779efb48149d3baa3a8e (upstream's `rtl/crt_adjust.sv`), by rmonic79 (Umberto Parisi) with Andrea Bogazzi (asturur); copied from the owner's Aquarium core with its three local changes (below), none added here | GPL-3.0 or later |

To add or update one: copy it from upstream at a commit and record it here.

## crt-adjust (three local changes, from the owner's other cores)

`crt_adjust.sv` (marked "Hexion core"): the line buffer's size `AW` is a parameter (upstream a localparam, 10). The module writes
a whole line, from the hsync's rise, into one of two banks of 2^(AW-1) samples; the M2's picture ends 810 pixels after the hsync
rises (Hell Night's 612), so `rtl/m2_crt.sv` uses 11.

`crt_adjust.sv` (marked "Aquarium core"): a new input, `vtotal`, the frame's lines, takes the place of the `VTOTAL` parameter in a
negative V-Shift's tap (`vtotal - |N|`); `VTOTAL` stays the vsync shift register's length, the most lines a frame can have. Here
it's 262 lines, or 416 with Hell Night's raster.

`crt_adjust.sv` (one line, `hoff_s`): the conditional mixes `$signed(hoffset)` with an unsigned replication, so by the Verilog
rules (and in Verilator) the result is unsigned and a negative H-Position is zero-extended (-1 becomes 511), which moves the
picture window out of the line and blanks the picture. The line sign-extends `hoffset` explicitly, which is what the module is
meant to do and gives the same result in every tool.
