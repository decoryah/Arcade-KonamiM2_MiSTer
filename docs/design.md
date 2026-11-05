# Design plan

## Budget

The DE10-Nano's 5CSEBA6 has 41,910 ALMs, 553 M10K and 112 DSP blocks. The MiSTer framework takes about 6,700 ALMs (the
Gaelco 3D core's fitter report), so the machine has about 35,000, and a build near 99 % still has to meet timing.

| Block | Estimate (ALMs) | From |
|---|---|---|
| PPC602 integer core, MMU, 4 KB + 4 KB caches (M10K) | 5,000-7,000 each | TG68K 3.7K; Gaelco 3D's TMS pipeline 8.3K with its FPU |
| PPC602 FPU (double precision, as MAME runs even the single-precision ops) | 1,500-2,500 each | Gaelco 3D's `g3d_fadd` ~300, `g3d_fmul` ~300, `g3d_fdiv` ~1,000 |
| Triangle engine | 10,000-15,000 | Gaelco 3D's rasterizer 16.5K, 7.3K of it float units; M2's TRAM needs no texture cache |
| BDA's DSP, VDU, DMA, bus | 3,000-5,000 | Gaelco 3D's ADSP-2115 3.2K |
| CDE / ATA, I/O, SDRAM, DDR3 arbiter | 1,000-2,000 | Gaelco 3D's arbiter 275, SDRAM controller 194 |
| **Total** | **28,000-41,000** | |

It fits only at the low end. Levers: one FPU shared by the two CPUs; iterative dividers where one result a clock is not
needed; the float units unpipelined on a two-clock multicycle path (as Gaelco 3D's TMS); no MPEG unless Polystars uses it.

## Memory

- Main RAM (Polystars: 8 MB) in SDRAM. The bus is 64 bits at 33.33 MHz (266 MB/s); the 16-bit SDRAM at 133 MHz peaks at a
  similar rate, so the CPUs' caches carry the load.
- Frame and Z buffers: block RAM if Polystars draws 320 x 240 (16-bit colour and Z, double-buffered: ~3.7 Mbit), else DDR3;
  CPU reads of them go through a coherent path.
- DDR3 arbiter: Gaelco 3D's `g3d_ddrarb` (fixed priority, scan-out first, pipelined reads, the write-starvation guard).
- The CD image: served by the HPS as the other CD cores do.

## Order of work

1. **Capture** (`tools/lua/m2_capture.lua`): which TE features, texture formats and resolution Polystars uses, how busy each
   CPU is (does `ppc2` do much?), where the lists and the CPUs synchronise. Needs the CD image (`623jaa02.chd`).
2. **PPC602 core**: a one-instruction-at-a-time reference model, then the pipeline, each checked on random programs and
   against MAME's core (Gaelco 3D's `tms_core` / `tms_pipe` method). Boots the 623B01 boot ROM against MAME's trace.
   Done so far: the model, the one-at-a-time RTL core and its float unit, the pipeline (below), and the bring-up on the
   board (ppc1 on the boot ROM from DDR3, below), the pipeline at 66.67 MHz, its caches, the CDE, `ppc2` with the caches snooping.
3. **Triangle engine**: done, in RTL straight from `3dom2_te.cpp`, against MAME's memory either side of a list (below).
4. **Memory system**: everything in DDR3 so far, the CD image through the HPS.
5. **VDU, CDE / ATA, Konami I/O**: done, the whole board against MAME's pictures from power-on. **The audio DSP** is next.

## The PPC602

What it has to be is what MAME 0.289 runs (`cpu/powerpc/ppcdrc.cpp` with `PPCDRC_COMPATIBLE_OPTIONS`, on its x64 back end),
where that differs from the real 602; the differences are listed in `tools/ref/ppc602/ppc602.h`. The ones that matter most:
the single-precision instructions are double-precision steps then a round to single (fmadds is a double multiply, a double
add, a round; nothing is fused); the floats are x86 SSE's (denormals kept, SSE's NaN rules, the default NaN
0xfff8000000000000); `tlbld` / `tlbli` do nothing, so with translation on an address no BAT maps is a TLB miss unless HID0's
protection-only bit maps it to itself; the rounding mode follows FPSCR[RN] only through mtfsb0/1, mtfsf and mtfsfi.

| | | Checked by |
|---|---|---|
| `tools/ref/ppc602/` | the reference model, an instruction at a time | `sim/ppcreplay` against MAME's traces |
| `rtl/ppc_core.sv` | the RTL core, an instruction at a time (no pipeline, no caches); BATs, the 603-style TLB-miss exceptions, the 602's esa / dsa | `sim/ppccore` (random programs against the model), `sim/ppcreplay` with `RTL=1` |
| `rtl/ppc_fpu.sv` | its float unit: MAME's sequence of x86 operations for each instruction, one step at a time through one rounder for double and single; divide and square root two bits a clock (29 clocks, the trial subtractions side by side). In the pipeline (`FULL = 0`) only divide, square root, fres and frsqrte, each step in clocks of its own (unpack, start, iterate, normalize, round) | `sim/ppcfpu` (random operands against the model), and the two above |
| `rtl/ppc_pipe.sv` | the pipeline: the same semantics, an instruction a clock when nothing stalls (fetch, X, M); `rtl/ppc_fpp.sv` beside it for the float ops, `ppc_fpu` for divide and square root | `sim/ppccore` and `sim/ppcreplay` with `PIPE=1`; `sim/ppcreplay -free` for its clocks |
| `rtl/ppc_cache.sv` | its caches, 8 KB + 8 KB (below) | `sim/ppccore` with `PIPE=1 CACHE=1`, `sim/m2boot` |
| `rtl/m2_cde.sv` | the CDE: registers, soft reset, DMA (below) | `sim/m2boot`, against MAME's PCs and register log |

The MAME traces (`tools/lua/ppc_trace.lua`, in `work/cap/`): the boot ROM from power-on (581,443 instructions), and one frame
of each CPU from frame 900 of Polystars' attract mode (1.30 M and 1.32 M instructions, with interrupts, TLB-miss exceptions
and timer reads). Model and RTL replay all of them without a difference.

How fast it has to be: at frame 900, `ppc2` runs about 557,000 instructions a frame outside its idle loop (33 M a second, a
third of them float), `ppc1` 284,000. At 66.67 MHz that is at most two clocks an instruction, cache misses included, so the
core that goes in the machine is the pipeline, not the one-at-a-time core.

### The pipeline

- **Fetch** is virtually indexed: the address goes out unregistered, its translation follows the next clock. One fetch out,
  a skid register behind it. A `b`, or a `bc` statically predicted taken (backward, or forward with the y bit; branch
  always), sends the next fetch to its target the clock it comes back, so a correctly predicted branch costs nothing.
- **The registers** are in RAM (`rtl/ppc_regs.sv`: a bank per write port, a copy per read port, a live value table): the
  GPRs with three read ports and two write ports (X / divw / SEQ, and M's load), the FPRs with four and two (the float
  units, and M's load or move). They're read the clock before X, for the instruction X will hold; X takes what was
  written since from the writes it keeps; a register written in the clock itself (M's load or FP move, a float result) makes
  X wait a clock (`FWD`, off).
- **X** decodes, executes and writes back in one clock, resolves branches (one predicted the wrong way, a taken `bclr` /
  `bcctr`, or a refetch costs a clock) and sends the data request with its virtual address.
- **M** is the address clock: the translation, the physical address out (or the request killed), and the fault, still
  precise: the instruction in X then isn't taken, and an update form's rA, written in X, is put back. A store that
  covers an instruction already fetched refetches after it. An access retires here, perhaps with the instruction behind
  it. The response may come that clock (as a cache hit would) or later; one access out. lmw / stmw / lsw / stsw / dcbz /
  stwcx. run one access at a time with M empty, divw in a state of its own, exceptions in one clock (SRR0, SRR1, MSR)
  then the vector. stfs converts to single in X, over four clocks (below).
- **The float pipeline** (`ppc_fpp`): M0-M4 (the multiply, on four DSPs), A0-A3 (the add; fnmadd's negation after it),
  S0-S2 (round to single, or the conversion to an integer), then the write; an op goes through the stages it needs:
  fmadds 12 clocks, fmul 5, fadd 4, frsp 3. One op issues a clock; reservations of A0, S0 and the write keep them apart.
  A result goes to the next op's operands as it leaves its last stage, and a multiply-add's addend may come that late,
  as the op reaches A0. Divide, square root, fres and frsqrte (MAME's square root then 1.0 / it) go to `ppc_fpu`, with
  the pipeline empty. fcmpu and the moves are X's.

`sim/ppcreplay -free` runs the frame-900 traces through the pipeline at memory with no latency (the data from the model's
accesses, the interrupts and timer values where the trace has them) and counts clocks and what each lost one waited for:

| | outside the idle loop | waiting on the float pipeline | on divide / square root | no instruction |
|---|---|---|---|---|
| `ppc1` (284 K instructions) | 1.66 clocks an instruction | 126 K clocks | 43 K | 15 K |
| `ppc2` (177 K) | 1.68 | 65 K | 47 K | 7 K |

(Before the float pipeline was staged for the clock: 1.33 and 1.37.) The float waits are mostly an op on a result of the
one before it (stfs, fcmpu, a multiply-add's product); divide / square root is nearly all frsqrte, back to back (`ppc2`
689 of them a frame, about 70 clocks each), the second waiting for the one unit. The caches' misses come on top of this.

**Its fit.** `ppc_pipe` alone (Quartus 17.0, 5CSEBA6, virtual pins, a 15 ns clock): 16,100 ALMs, about 2,000 of them
the virtual pins' (`ppc_fpp` 2,800, `ppc_fpu` 1,900, the register files 200 with 24 M10K), 10 DSPs. Before the float units
were staged and the registers went to RAM it was 34,100 ALMs with a 71 ns worst path. It then made 21.3 ns. What took it to 15 ns (66.67 MHz), each checked on all the benches, for a cost of 3.81 to 3.94
clocks an instruction on the random programs:
- no forward of M's load or a float unit's result to X in the clock it is written (`FWD`, now off);
- a store's check of the instructions already fetched compares offsets in the page, needing no translation: a match in
  another page only refetches;
- the multiplies and `fcmpu` / `fcmpo` take two clocks in X, their results registered;
- `stfs` takes four: its conversion to a single (28 ns placed) is a multicycle path of 2 (`cvt_x`, `cvt_m` to `cvt_r`, in
  `KonamiM2.sdc`), with X waiting.

A fit of `ppc_pipe` alone doesn't time its bus: virtual pins hide what follows `d_wdata` and `d_pa`. The `stfs` conversion
only showed in the whole core (-13.3 ns), as did the bring-up's decode of the access in the address clock, now a clock later.

Quartus 17's elaborator crashes (internal error in `veriname_elab.cpp`) on a function that reads a module's unpacked
array indexed by an argument (`sr[a[31:28]]` in `translate`), and rejects a write to one field of a struct variable in some
functions (`s0.last = 1'b1` in `ppc_fpu`'s `prog`). Verilator accepts both; the sources avoid them.

## The caches (`rtl/ppc_cache.sv`)

8 KB of instructions and 8 KB of data, 32-byte lines, direct-mapped; indexed by the virtual address (BATs map 128 KB or more,
and pages aren't mapped, so the low 13 bits don't change), tagged by the physical.
- A fetch hit answers in its address clock: a fetch a clock. A miss reads the line and asks again. Its tags have a second copy
  read by the data side's address, so each store checks them: code written is never stale. Fetches that aren't memory read
  zeros, decided at the miss: a decode in the hit's path was the worst path of the core.
- A load hit answers the clock after its address clock. Write-through, no write allocate: a store goes to a buffer of four,
  and into the line on a hit, the clock after, with `d_rdy` low.
- An access across 8 bytes, or not cacheable, goes alone once the buffer has drained; a store across 8 bytes invalidates its
  one or two lines in both caches. The first version swept all the tags for it, 256 clocks each: a 4-aligned `stfd` crosses
  8 bytes half the time.
- DDR3 takes one job at a time, the store buffer first. A line read waits for the buffer to empty, so nothing reads older than
  a store done.
- No `dcbf`, `icbi`, HID0 or WIMG yet: nothing else writes memory. They come with the other bus masters. Real 602 software
  manages the caches itself, so when they come those instructions have to work.

`sim/ppccore` with `CACHE=1` runs the random programs through it, memory the bench's own with random latency; each load's value
is also checked as it comes. Ten deliberately broken copies of the cache tested the test. Four went unnoticed at first (a store
meeting a line being fetched is rare), so a sixth of the programs' instructions are now stores just ahead of themselves
(through r28-r31, in the middle of the program), and a third of the cases have memory busy 90 % of the time, so the buffer
fills. All ten are then caught, and two real bugs turned up: a refetch hitting the second line of a store across 8 bytes before
its invalidate, and a store in the very clock a fetched line's tag is written.

Past the power-on trace (`-more`) the boot code runs at about 1.42 clocks an instruction.

## The bring-up (`rtl/m2_boot.sv`)

Until the rest of the board exists, the core is ppc1 alone on the boot ROM, so the CPU can be tried on the board:
- ppc1 (`ppc_pipe`, its bench outputs off) at 66.67 MHz, DEC / TB ticking every 8 clocks;
- the boot ROM (623b01.8q, downloaded by the MRA through `ioctl`, a handshake into the CPU's clock) and main RAM (16 MB,
  more than Polystars' 8) in DDR3 from 0x30000000, through the caches, the download writing DDR3 directly under reset;
- the board's registers as stubs: each keeps what is written (16 of them), the ones MAME makes constants read those (the
  CDE's DEVICE_ID, SYSTEM_CONF = 0x63659000 and others, CPUID 0x40000000), the VDU's read 0 but VINT and VLOC (the video
  line, as MAME computes it: ((line + 20) % 260 + 1) << 3);
- a status screen, since removed for the room: the last PC, the instructions retired, exceptions, the register accesses and the
  last read and write, taken in the CPU's clock once a frame so they hold still while shown.

`sim/m2boot` runs it with a DDR3 model (random wait states and latency) on the ROM, downloaded through the loader, and
checks each instruction retired against MAME's power-on trace: all 581,443 match (1.49 clocks an instruction with DDR3
answering in 2 clocks, 1.50 with the random latency; 3.7 and 7.5 before the caches). With `-more`, it runs on past the trace: through the RAM test, the
board's ID check (SYSTEM_CONF) and the VDU's setup and its wait for a line, to where the boot ROM resets the CPU through the
CDE (RESET_CNTL, at about 0.5 seconds), then on through its second pass (below).

Early builds ignored that write, and ran on through the code after it for good. What they showed as a wait for the
CD drive was this: the boot never got as far as the drive.

**The CDE** (`rtl/m2_cde.sv`) is now what MAME makes of it: its registers, the soft reset (the CPU's only; BBLOCK_EN then reads
0, which sends the boot ROM on to load the OS), and its DMA. The DMA is the first bus master besides the CPU. It takes DDR3 when
the caches aren't using it, and at its end all the tags in both caches are swept (`inv_all`, 256 clocks), so nothing it wrote is
stale: MAME has no caches, so the software is known to run with memory coherent, and `dcbi` and the like stay no-ops. On
the second pass the boot ROM copies the OS from ROM to RAM (0x40xxxxxx) and runs it.

**Where it stops now: the second CPU.** At about 0.6 seconds the OS (`ppc1`, 4001F9BC) waits for the word at 0x407F9140, 5 when
it gets there, to clear. In MAME `ppc2` clears it (a watchpoint: 0 written at 4001F9D8, the same code). The loop has a `dcbi` in it,
so with two CPUs that has to work, or the caches snoop; it is a no-op now. So `ppc2` comes before
the CD drive: the first ATA access is at frame 79, this wait at frame 30.

MAME's boot, captured (`work/lua/cd_wp.lua`), uses the CD drive thus, once it gets there: ATAPI through the data and task file
registers at 0x3f000000, polling (bit 13 of 0x37e00006 is the ATA interrupt): IDENTIFY PACKET, TEST UNIT READY, REQUEST SENSE,
READ TOC (each track, 28 of them), MODE SENSE (page 0x0e), READ CAPACITY, then READ(12), one sector of 2048 bytes at a time,
with the CDE's DMA from the data port to RAM. A small subset, as the plan hoped.

An early build, the CPU at 66.67 MHz, ran 18 minutes on the board in that endless run-on with no exceptions, its counters agreeing
(5.8 M instructions a second, against 3.9 M at 33.33 MHz: DDR3's latency doesn't shrink with the clock). That wait is a small
part of the CPU: the float units are tried at this speed only in simulation so far. The next adds the caches
(21,687 ALMs, +0.27 ns): over 10 minutes on the board in the same place, no exceptions, at 47 M instructions a second, as
`sim/m2boot -more` predicts (about 1.42 clocks an instruction): in that loop DDR3's latency no longer matters.

On the board (the CPU at 33.33 MHz, HDMI) it does the same: PC 20000830, no exceptions, after minutes of running. The board showed
two faults of the status screen that no bench had. A fractional pixel enable (MAME's 11.944 MHz on 66.67 MHz, pixels 5 or 6
clocks apart) made rows of the letters jitter sideways through the scaler, so its raster (`rtl/m2_vtiming.sv`) is now 714 x
262 at 59.40 Hz, 66.67 MHz divided by 6. The real VDU will want MAME's raster and a clean pixel clock for it. And one line
saying LAST READ or LAST WRITE, whichever came last, flickered between the two words.

## The rest of the machine

`rtl/m2_atapi.sv` is the drive, the subset MAME's boot uses, its sectors from the image in DDR3; `rtl/m2_kio.sv` the
inputs and the 93C46; `rtl/m2_vdu.sv` walks the display list and scans the frame out of DDR3. The control port (0x00070000) has nothing behind it:
MAME's reads are random, and the OS's driver goes by them. With a read of 0 it sees a transfer that worked and its start-up never finishes, so
the core's are random too.

The delay loops in the OS (4005C500, 12.6 M rounds three times over, a screen each) take about twice as long as in MAME, which doesn't count
memory: the title screen comes at about frame 1000 in simulation, 540 in MAME.

## The Triangle Engine

`rtl/m2_te.sv`: the list, the setup in single precision in the order of MAME's C, the walk, then a pipeline, a pixel a clock, four for a textured
one, as TRAM has one port. Its stages are listed in the source. Z and the colours have a write-back cache each (`te_cache`, 128 lines of 32 bytes,
one read and one write a clock), whose writes allocate without reading: each byte has a bit for whether it's been written, so a frame that's only
written costs no reads. Everything stalls together on a miss.

`sim/te` checks it: `work/lua/te_dump.lua` dumps MAME's RAM and registers before successive lists, the bench runs a list, and compares each byte
written with the next dump. All the attract mode's lists dumped so far are the same to the byte (and with memory three times slower).

MAME runs three lists a frame in attract mode: 0.13, 0.65 and 0.94 M clocks at 66.67 MHz, with memory answering in 12 clocks: about 1.7 M against
the frame's 1.12 M. In simulation the whole machine runs 1.5 lists a frame, half of MAME's rate. If the game turns out slow for this, two or four TRAM ports are what's left to gain. The pixel-at-a-time machine it
replaced took 9 M. The compressed texture load isn't there: no list seen uses it.

## Timing references

MAME gives no TE timing (lists run in zero time) and MAME's Polystars runs at the wrong speed; the CPU timing is MAME's
approximation. Real-hardware video of the game is the reference for speed.
