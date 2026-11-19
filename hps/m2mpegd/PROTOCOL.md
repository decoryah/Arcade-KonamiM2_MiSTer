# m2mpegd protocol: the DDR3 block between the core's MPEG unit and the ARM daemon

Version 1, 2026-11-15. The core's `rtl/m2_mpeg.sv` (with `MPEG_HPS`) keeps the MPEG unit's control side (registers, bitstream fetch, start codes, interrupts); the daemon
`m2mpegd` on the MiSTer's ARM decodes the pictures and writes the formatted pixels into game RAM. They meet in one block of
DDR3. The daemon side is `src/m2mpegd_core.cpp` (run by `src/m2mpegd.cpp`); the core's bench `sim/mpeg/tb_mpeg_hps.cpp` runs
it against the RTL on the emulator's MPEG dumps.

## Where

- **The block:** `BASE` = 0x30400000 (`rtl/m2_boot.sv`: after the ROM, before a debug build's rings), 0x50000 bytes
  (320 KB), 512 KB-aligned, in the core's DDR3 window (0x30000000 +). The core's bus reaches it at 0x58000000 + (no CPU's
  addresses). The daemon takes it as an option (`--base 30400000`, as `scripts/m2mpegd_service.sh` gives it).
- **Game RAM:** DDR3 0x31000000 + (M2 address - 0x40000000), 16 MB (`rtl/m2_boot.sv`'s map). M2 data there is in the
  M2's byte order: the byte at M2 address A is at DDR3 byte 0x31000000 + (A - 0x40000000).

## Byte order

- **Control words** (header, beat, log entries, present, done): 64-bit words, stored as the core's DDR3 port stores any
  64-bit word it builds, bits 7:0 at the lowest byte address (as `rtl/m2_fps.sv`'s ring): on the ARM, a native
  (little-endian) load gives the value. Bit numbers below are of that 64-bit value.
- **M2 data** (register values inside log entries are numbers, not bytes; the bitstream ring's bytes; the pixels the
  daemon writes into game RAM): in M2 byte order, i.e. as the M2 sees memory (32-bit words big-endian).
- So: **control words little-endian** (like `m2_fps.sv`), **M2 data in M2 order** (big-endian words), as the core's
  other DDR3 writers.

## Layout (offsets from BASE)

| Offset | Size | Contents | Writer |
|---|---|---|---|
| 0x00000 | 8 | header: [63:32] magic 0x4D324D50 ("M2MP"), [31:16] version (1), [15:8] log2 of log entries (12), [7:0] log2 of bitstream ring bytes (18) | FPGA, after its reset clear (last) |
| 0x00008 | 8 | beat: [31:0] a count, +1 every 2^20 clocks (about 16 ms); [63:32] 0 | FPGA |
| 0x00040 | 8 | present: [63:32] magic 0x4D504744 ("MPGD") while a daemon is attached, else 0; [31:0] heartbeat, +1 about every 5 ms | daemon |
| 0x00048 | 8 | done: [31] 1, [12:0] the sequence number of the last picture-end entry whose pixels are written; [63:32] 0 | daemon |
| 0x00050 | 16 | 0 (the rest of the 32-byte line the FPGA reads) | |
| 0x00080 | 64 | daemon statistics (diagnostic; the FPGA never reads them): pictures, late pictures, resyncs, errors, worst ms | daemon |
| 0x01000 | 32 KB | the log: 4096 entries of 8 bytes | FPGA |
| 0x10000 | 256 KB | the bitstream ring: picture data bytes in stream order | FPGA |

The line at +0x40 (present, done) is the only thing the FPGA reads: 32 bytes, one read. The daemon writes each of its
words' low 32 bits with one 32-bit store (single-copy atomic on the A9), and the present magic once when it attaches and
once when it leaves.

## The log

Entry n (n counted from 0 at the FPGA's reset) is at +0x1000 + 8 * (n mod 4096):

| Bits | Contents |
|---|---|
| [63] | 1 (a written entry; the reset clear leaves 0) |
| [62:61] | kind: 0 a register write, 1 a picture's end |
| [60:48] | n mod 8192 (so an entry of the lap before is told from a new one) |
| [47:0], kind 0 | [47:40] 0, [39:32] the register's word index (byte offset >> 2: offsets 0x000-0x3FC), [31:0] the value written |
| [47:0], kind 1 | [47:24] the picture's data length in bytes, [23:0] the stream position just after its last byte (mod 2^24) |

- **Kind 0:** every CPU write to 0x00080000-0x000803FF, in the order the unit takes them (all of them, quant tables
  included; the daemon keeps its own copy of the registers from these, as `m2mpeg_regs::write`).
- **Kind 1:** written where the unit finishes a picture (the control stub, without `MPEG_HPS`, raises the end-of-picture interrupts 0x32 there:
  after the start code that ends the slices and its two read-ahead bytes, or at once for a vertically cropped B picture),
  after the picture's last bitstream ring byte.
- The FPGA writes an entry in one 64-bit DDR3 write. A writer that can't (a bench) writes bits 31:0 first,
  then bits 63:32. The daemon reads bits 63:32 first and the low half only once those say the entry is the one it wants.
- The FPGA never waits for the daemon to read the log. 4096 entries are about 60 pictures of Tryst's (about 68 writes a
  picture); a daemon that falls further behind sees a sequence number from a later lap, and resynchronizes (below).

## The bitstream ring

Every byte the unit puts into a picture's data (the bytes the emulator's `m_picture_data` collects: from the first slice
byte through the start code that ends the picture; not the two read-ahead bytes) is stored at +0x10000 + (p mod 262144),
where p is the stream position, counted from 0 at reset; then p += 1. The picture-end entry gives the picture's length L and
the position P after its last byte: its data is positions P - L to P - 1 (the ring holds the last 256 KB; a picture is at
most a few tens of KB).

How the FPGA writes the ring is its own choice: the daemon reads bytes. One byte-enabled DDR3 write per byte is the least
logic (the ROM download writes bytes that way) but about 16 K writes a Tryst picture; packing 8 bytes into one 64-bit write
(a 64-bit shift register and a byte count, about 70 flops; at a picture's end the part-filled word written with its byte
enables, and the next picture's bytes going on in the same word) cuts that to about 2 K, which matters on a bus shared with
the CPUs and the Triangle Engine. Either way every byte must be in DDR3 before the picture-end entry that covers it. (The
core writes a byte a write: Battle Tryst's build has no room for the packing word.)

**The FPGA mirrors the picture data into this ring.** The real unit holds what it has
fetched in its own FIFO, so the M2 driver may recycle a bitstream buffer (the stream refills it from the CD) as soon as the
unit has taken it (the VBS DMA interrupt); the ring does the same job, so there is no race. Considered and rejected: the daemon copies each buffer from game RAM as soon as its VBSNEXTADDR / VBSNEXTLEN
writes appear in the log. That needs no ring, but it races the refill (the stub keeps nothing; the window is the time
between the VBS DMA interrupt and the CD's first sectors landing in the freed buffer, likely a few ms, never guaranteed),
and the daemon would have to model the DMA's current / next buffer rules exactly; a per-picture byte count and sum from the
FPGA would only detect a lost race, not prevent it.

## The FPGA's rules

1. **Reset:** write 0 over the log (4096 entries) and the line at +0x40 (present, done: a block left by an earlier core or
   session is not taken for a live daemon); then the header. n = 0, p = 0. (The bitstream ring needn't be cleared.)
2. **Beat:** every 2^20 clocks, +1 at +0x08.
3. **Each register write and each picture byte:** as above. The write path takes DDR3 in clocks nothing else wants it (as
   `m2_fps.sv`'s `wr_ok`); the CPU's write or the parser waits while an entry or byte is pending.
4. **A picture's end:** append the kind-1 entry (sequence number s = n mod 8192 of that entry), then decide:
   - read the line at +0x40;
   - if present's magic isn't "MPGD", or present's heartbeat equals `dead_beat` (below): raise 0x32 now (no daemon: the stub's
     behavior);
   - else **hold**: read the line again about every 2^14 clocks (0.25 ms) and raise 0x32 when done = 0x80000000 | s;
     - if the heartbeat hasn't changed for 50 ms: `dead_beat` = that heartbeat; raise 0x32 (a killed daemon costs one
       picture 50 ms; later pictures don't wait, until a daemon's heartbeat moves again);
     - **time-out:** if held 120 ms, raise 0x32 anyway (the daemon is alive but late; the worst picture
       measured was about 40 ms, so the time-out is only a guard).

   A late "done" (one naming an entry the FPGA no longer waits for) is ignored.

## The daemon's rules

1. **Attach** when `/tmp/CORENAME` names a core it serves, the header's magic and version are right, and the beat moves
   (two reads 50 ms apart differ). Map the block (`/dev/mem`, O_SYNC) and game RAM (`/dev/m2_mem_wc`, write-combined,
   when `kernel/m2_mem_wc` is loaded; else `/dev/mem`).
2. **Start** after the newest entry in the log (scan the 4096 entries' sequence numbers): earlier pictures are not decoded.
   Write present (magic, heartbeat) and keep the heartbeat moving from a thread of its own, also while decoding.
3. **Read** entry n: bits 63:32 first. [63] = 1 and [60:48] = n mod 8192: take it. [63] = 0, or [60:48] = (n - 4096) mod
   8192: not written yet, poll again (sleeping about 0.1 ms between polls). Anything else (the FPGA reset, or the daemon
   fell a lap behind): **resynchronize** (2.) and forget the reference pictures.
4. **Kind 0:** apply to the register copy. **Kind 1:** copy the picture's L bytes from the ring, decode, format (the
   emulator's decoder and formatter, byte for byte), write each formatted row the formatter writes into game RAM at its M2
   address (rows outside RAM are skipped, as the emulator does), a `dsb`, then done = 0x80000000 | s. A picture that comes
   after the time-out is still written (in order; a later picture can't be written before it), and counted as late.
5. **Leave** when the beat stops for 200 ms, the header's magic goes, or `/tmp/CORENAME` changes: clear present's magic,
   unmap, forget the pictures. On SIGTERM / SIGINT the same.
6. Runs at raised priority (`nice -n -20`) while attached; at normal priority while it waits. Logs to `/tmp`.
7. **A core reset** is seen two ways while idle: the beat goes down, or present's magic no longer reads "MPGD" (the FPGA's
   reset clear is the only thing that clears it). Either: start again at entry 0, forget the pictures and the register
   copy, write present again. After a reset seen through present, wait 1 ms (the FPGA writes the beat after the line) and
   take the beat afresh, so the restarted beat isn't a second reset. (Without the second way, a reset while the beat was
   still 0, or one after which it passed its old value before the daemon looked, isn't seen.)

## The RTL's side

- `rtl/m2_boot.sv`: the block at the bus's addresses 0x58000000 + (no CPU's); the unit's `hold` keeps a register access
  from starting while its entry queue is nearly full.
- `rtl/m2_bus.sv`: master 7 (the MPEG unit) can write a word; it reads the line at +0x40 as a 4-word line.
- `rtl/m2_mpeg.sv`: the entry queue (16 entries; a register write may wait), the ring byte write per parsed byte, the hold
  state with its line poll, the 50 ms heartbeat check and `dead_beat`, the 120 ms time-out, the reset clear.
- The game's CPU caches don't see the daemon's writes (they bypass the bus's snoop). The real unit's output doesn't
  snoop either (the M2 OS's MPEG driver leaves the snoop bit off), so the game can't rely on it; Tryst's TE reads
  DDR3 directly. The TE's color and Z caches are written back and emptied when a list stops (`rtl/m2_te.sv`), so a list
  reads each line from DDR3 when it first needs it; a line it fetched before the daemon wrote it stays old to the end of
  that list.
