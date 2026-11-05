# The Konami M2 board

What MAME 0.289 knows of it (`konami/konamim2.cpp`, `konami/3dom2.cpp`, `konami/3dom2_te.cpp`; copies in `../work/mame/`).

## CPUs and clocks

- Two PowerPC 602s (`:ppc1`, `:ppc2`) at `M2_CLOCK` = 66.6667 MHz, their bus at half that (33.33 MHz, 64 bits wide,
  big-endian). Both see the same address map.
- `ppc1` takes the BDA's PowerBus interrupt; `ppc2` takes the memory controller's GPIO 3 (inverted).

## Address map (physical, as both CPUs see it)

| Address | Size | What |
|---|---|---|
| `0x00010000` | 64 KB | BDA PowerBus (interrupts) |
| `0x00020000` | 64 KB | BDA memory controller |
| `0x00030000` | 64 KB | BDA VDU (video) |
| `0x00040000` | 64 KB | BDA triangle engine (TE) registers |
| `0x00060000` | 64 KB | BDA DSP ("DSPP Bulldog"): the sound |
| `0x00070000` | 64 KB | BDA control port |
| `0x00080000` | 64 KB | BDA MPEG |
| `0x000c0000` | 16 KB | TE texture RAM (TRAM) |
| `0x04000000` | 16 MB | Slot 4: the CDE |
| `0x10000000` | 64 KB | CPU ID |
| `0x20000000` | 2 MB | boot ROM (BIOBUS slot 0), also at `0xfff00000` |
| `0x37400000`.. | | Konami: EEPROM, ATAPI, I/O 0, serial, I/O 1 |
| `0x3f000000` | 16 MB | ATA (the CR589 CD drive), byte-swapped |
| `0x40000000` | 2 banks | main RAM: Polystars 2 x 4 MB (`RAM_4MB`); the other games 2 x 8 MB |

The BDA's 32-bit units sit on the 64-bit bus with a full mask: the upper half of a beat is the lower address.

## Polystars' configuration

`polystar(config)`: the base machine, RAM 2 x 4 MB, NTSC video. No sub board, no YMZ280B, no M48T58. The sound is the BDA's
DSP and the CD's audio tracks (through the CR589's CD-DA). Boot ROM `623b01.8q` (2 MB), EEPROM `93c46.7k`, CD `623jaa02`
(a CHD; MAME flags it `BAD_DUMP`: one second of silence near the start of the first audio track).

## Video

`set_ntsc()`: 768 x 262 at 59.36 Hz (a pixel clock of 11.944 MHz), 640 x 240 shown from (126, 20). The VDU reads a video
display list (VDL) from RAM; its registers (`VINT`, `FV0A`, `FV1A`, `VCFG`, `VRST`, ...) set the line interrupts and where
the lists are. The frame buffer is 16 or 32 bits a pixel (`VDL_LC_FBFORMAT`).

## Triangle engine

Registers in five units, by address bits [15:13] (offset bits [13:11] of the 32-bit word index), with the write mode in
bits [12:11] (write, -, set bits, clear bits):

| Unit | What |
|---|---|
| 0 GC | master mode, instruction control (start / restart, stop at list end / each instruction), deferred control (jump, texture load, pause, interrupt), IWP / IRP, interrupts |
| 1 SE | setup engine: three vertex slots (x, y, r, g, b, a, w, u/w, v/w), the vertex state (fan / strip order) |
| 2 ES | edge walker: start values and slopes |
| 3 TM | texture mapper: PIP RAM (256 words) below `0x400`, then texture control, load control, address control (filter: point / linear / bilinear / quasi-trilinear, per LOD range), LOD bases, source and expansion formats |
| 4 DB | destination blender: user / supervisor control, window and Z clipping, destination and source buffers (16 / 32 bpp, base, stride), Z buffer, blend multipliers, ALU, alpha control, dither |

Command lists in RAM, read from IRP until IRP = IWP:

- `0x1nnn_oooo`: write `nn + 1` registers from offset `oooo`;
- `0x20..`: short vertices (`cnt + 1` of them): x, y, then r g b a if SHAD, w if PRSP, u/w v/w if TEXT; NEW starts a new
  triangle, RM selects fan rather than strip;
- `0x30..` long vertices, `0x40..` points: unimplemented in MAME (a fatal error).

Texture RAM is 16 KB, filled by explicit loads (`TEDCntl` TLD): uncompressed, or compressed (run-length; MAME's compressed
path is unfinished: "Fix texture compression").

**MAME runs a list to its end inside the CPU write that starts it**: no TE time passes. MAME's own notes (inside its
unused `TEST_TIMING` code) give the setup engine "600-700 triangles/sec (?)" and 132 / 66 / 33 / 22 Mpixel/s for point /
linear / bilinear / quasi-trilinear texturing.

## Known MAME issues that touch Polystars

- "Fix incorrect speed in Tobe! Polystars" (open).
- "Fix PowerPC 602 Protection Only mode handling" (open).
- "Fix texture compression" (open).
- Polystars' blending and its missing music: fixed.
