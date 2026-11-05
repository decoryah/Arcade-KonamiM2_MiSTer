#!/usr/bin/env python3
"""ppc_spr_scan.py: finds the instructions that write the PPC602 registers MAME's state interface doesn't show (BATs,
HID0, IBR, ESASRR through esa / dsa, the 602 and 603 SPRs), in the boot ROM and a RAM dump, for ppc_trace.lua's
breakpoints (PPCT_BP): one line per instruction, "pc kind spr reg" (kind mtspr, esa or dsa).

    python3 tools/ppc_spr_scan.py 623b01.8q ram.bin > spr_writes.txt

The boot ROM is at 0x20000000 (and 0xfff00000, where the CPUs start); the RAM dump (ppc_trace.lua's ram.bin) at
0x40000000. Code is assumed to run where it sits (the OS maps itself one to one).
"""
import struct
import sys

# SPRs MAME's state interface has, or that the bench supplies (LR, CTR, XER, DEC, SRR0/1, SPRG0-3, SDR1, TB)
IN_STATE = {1, 8, 9, 22, 25, 26, 27, 272, 273, 274, 275, 284, 285}


def scan(data, base, out):
    for off in range(0, len(data) - 3, 4):
        op = struct.unpack_from(">I", data, off)[0]
        if op >> 26 != 31:
            continue
        xo = (op >> 1) & 0x3ff
        pc = base + off
        if xo == 0x1d3:
            f = (op >> 11) & 0x3ff
            spr = ((f >> 5) & 0x1f) | ((f & 0x1f) << 5)
            if spr not in IN_STATE:
                out.append((pc, "mtspr", spr, (op >> 21) & 31))
        elif xo == 0x254 and (op & 0x03fff801) == 0:
            out.append((pc, "esa", 0, 0))
        elif xo == 0x274 and (op & 0x03fff801) == 0:
            out.append((pc, "dsa", 0, 0))


def main():
    rom = open(sys.argv[1], "rb").read()
    out = []
    scan(rom, 0xfff00000, out)
    scan(rom, 0x20000000, out)
    if len(sys.argv) > 2:
        ram = open(sys.argv[2], "rb").read()
        scan(ram, 0x40000000, out)
    for pc, kind, spr, reg in out:
        print(f"{pc:08X} {kind} {spr} {reg}")
    print(f"{len(out)} instructions", file=sys.stderr)


if __name__ == "__main__":
    main()
