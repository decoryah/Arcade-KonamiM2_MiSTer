# m2mpegd: the M2 MPEG unit's decoder on the MiSTer's ARM

Battle Tryst's build (`MPEG_HPS` in `KonamiM2.qsf`'s Battle Tryst block) has the M2 MPEG unit's registers, its bitstream fetch
and its interrupts in the FPGA (`rtl/m2_mpeg.sv`), but not the decoder. For each picture the unit writes the register writes and
the picture's bytes into a block of DDR3 and waits; `m2mpegd`, a program on the MiSTer's ARM, decodes the picture, writes it into
game RAM in the M2's pixel format, as the M2's own MPEG unit does, and says it's done. Without `m2mpegd` running, the game plays
normally and its movies are black. How to install and play is in the core's [README](../../README.md) ("Battle Tryst's movies").

| Here | What |
|---|---|
| `src/m2mpegd.cpp` | the daemon: waits for a core it serves (`/tmp/CORENAME`, default `btltryst`), maps the block and game RAM, runs the session until the core goes |
| `src/m2mpegd_core.*` | the session: the daemon's side of [PROTOCOL.md](PROTOCOL.md), on any mapping of the block and of game RAM (the core's bench `sim/mpeg/tb_mpeg_hps.cpp` runs it too) |
| `src/m2mpeg_unit.*` | the unit's picture path: registers in, slice bytes in, the output formatter's bytes out, as MAME's M2 driver |
| `src/3dom2_mpeg.*` | the MPEG-1 video picture decoder (ISO 11172-2), as in MAME's M2 driver; `emu.h`, the one thing it takes from MAME's |
| `src/m2mpeg_protocol.h` | the block's layout and access (PROTOCOL.md) |
| `scripts/m2mpegd_service.sh` | starts and stops the daemon (`start`, `start once`, `stop`, `status`) |
| `scripts/Battle_Tryst_MPEG.sh` | for `Scripts/`: starts the daemon for one session and loads Battle Tryst |
| `scripts/m2mpegd_autostart.sh` | for `Scripts/`: turns starting the daemon at boot on or off (a line in `/media/fat/linux/user-startup.sh`) |
| `kernel/m2_mem_wc/` | an optional kernel module: game RAM mapped write-combined, so a picture's copy takes about 0.3-0.5 ms instead of 3.7. It has a second window, a 1 MB test block at DDR3 0x3C000000 that neither the core nor the framework uses, for measuring a mapping's speed; the daemon doesn't use it |
| `build_arm.sh` | builds `build/m2mpegd` |
| `PROTOCOL.md` | the DDR3 block between the core and the daemon (version 1) |

## Building

The daemon: on a Linux PC or in WSL, with Ubuntu's ARM compiler (`apt install g++-arm-linux-gnueabihf`):

```
bash hps/m2mpegd/build_arm.sh        # -> hps/m2mpegd/build/m2mpegd (static, Cortex-A9 with NEON)
```

It is built with `-ffp-contract=off`, so its pixels are the emulator's, bit for bit.

The kernel module is built for one kernel; `m2mpegd_service.sh` loads `m2_mem_wc-$(uname -r).ko` from its folder, and without
one (a MiSTer kernel the release doesn't know) the daemon copies through `/dev/mem`, as before: the movies still play. The two
scripts build it with the compiler the MiSTer kernel was built with (Arm GNU Toolchain 10.2-2020.11) on the kernel source
NDS4MiSTer pins for that release (both downloaded and checked against their checksums), and need make, gcc, flex, bison,
libssl-dev, libelf-dev and curl:

```
bash hps/m2mpegd/kernel/m2_mem_wc/kprep515.sh                  # -> ~/m2mpegd_kernel/m2_mem_wc-5.15.1-MiSTer.ko
bash hps/m2mpegd/kernel/m2_mem_wc/kprep618.sh config-6.18.38   # -> ~/m2mpegd_kernel/m2_mem_wc-6.18.38-MiSTer.ko
```

`kprep515.sh` uses `config-5.15.1-MiSTer` (here, a 5.15.1-MiSTer board's `/proc/config.gz`); `kprep618.sh` takes the 6.18.38
kernel's (`zcat /proc/config.gz` on a MiSTer running it). olddefconfig must leave the config unchanged: a module built with
another compiler (e.g. Ubuntu's gcc 13) gets a config with other settings, an ABI the running kernel doesn't have.

## On the MiSTer

| On the SD card | From |
|---|---|
| `m2mpegd/m2mpegd` | `build/m2mpegd` |
| `m2mpegd/m2mpegd_service.sh` | `scripts/` |
| `m2mpegd/m2_mem_wc-<kernel>.ko` | `kernel/m2_mem_wc/` (optional, one per MiSTer kernel) |
| `Scripts/Battle_Tryst_MPEG.sh` | `scripts/` |
| `Scripts/m2mpegd_autostart.sh` | `scripts/` |

`m2mpegd_service.sh start` runs `m2mpegd --base 30400000 --pace 22 --log /tmp/m2mpegd.log` in the background (`start once`
adds `--until-gone 60`, the launcher's mode). The daemon's options:

| Option | |
|---|---|
| `--base HEX` | the block's physical address (the core's: 30400000; no default) |
| `--cores name,name` | the `/tmp/CORENAME` values it serves (default `btltryst`) |
| `--log FILE` | its messages (default `/tmp/m2mpegd.log`: RAM, nothing is written to the SD card) |
| `--threads 1\|2` | a picture's work on one or both ARM cores (default 2) |
| `--pace MS` | each picture copied into game RAM MS after its data has come (default 0, as soon as it's ready). The game redraws the movie from game RAM every frame, so a copy at a fixed point in the frame stays clear of that read: the service gives 22, without which the movie tears |
| `--until-gone SEC` | exit once a served core has been loaded and has gone, or if none is loaded within SEC seconds |
| `--wc auto\|on\|off` | game RAM through `/dev/m2_mem_wc` when the module is loaded (auto), only through it (on), or through `/dev/mem` (off) |
| `--check` | print what it would do and exit (maps nothing) |

It raises its own priority (nice -20, so it runs as root) and leaves cleanly on SIGTERM / SIGINT. While no served core runs it
only reads `/tmp/CORENAME` once a second. Don't run it against a core without the MPEG block: it writes the block's words and
game RAM.

## Tests

- `sim/mpeg/run_hps.sh` (the core's): the unit built with `MPEG_HPS` and this folder's `m2mpegd_core` in a thread, on the M2
  emulator's MPEG dumps (made outside this repository): every log entry, each picture's bytes in the ring, how each picture is
  let go (no daemon, a killed one, a late one), and the pixels in game RAM against the dump's.
- `sim/m2boot` with `-DMPEG_HPS_TEST`: pictures through the whole core (the CPU, m2_bus, m2_boot) on a test ROM.

## Licences and credits

`src/3dom2_mpeg.cpp` and `.h` carry MAME's BSD-3-Clause header, as MAME's M2 files. `kernel/m2_mem_wc/m2_mem_wc.c` is
GPL-2.0, as a kernel module: it follows NDS4MiSTer's `nds_mem_wc` (https://github.com/SplashDev88/NDS4MiSTer, GPL-2.0), which
credits DreamSTer for the idea. The rest is under the repository's licence (`LICENSE`).
