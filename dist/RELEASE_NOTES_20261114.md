## Konami M2 for MiSTer - 20261114

Konami's **M2** arcade board (1997-1998), the 3DO M2 hardware: two PowerPC 602s at 66.67 MHz, a triangle engine, an audio DSP and a CD
drive. Six MRAs and four cores: **Tobe! Polystars** (ver JAA, 1997), the light-gun games **Evil Night** (ver UBA, 1998), **Hell Night**
(ver EAA, 1998) and **Total Vice** (ver EBA, 1997), the fighting game **Battle Tryst** (ver JAC, 1998) and the football game **Heat of
Eleven '98** (ver EAA, 1998).

**Three new games, each on its own core, for the SDRAM board.** Hell Night, Battle Tryst and Heat of Eleven '98 are tallendorf's work,
with the Z buffer in the SDRAM board's memory based on the repository owner's Gaelco 3D core. Like the first three, they're tested and
working on a real MiSTer: played by the repository owner on this release's cores, and by tallendorf on a MiSTerPi, a MultiSystem 2 and
a DE10-Nano. With them every game of MAME's Konami M2 driver is supported, Total Vice in its EBA version.

### What's new

- **Hell Night:** Evil Night's European version. It draws only in High Res, on the arcade monitor: 512 x 384 at about 24 kHz, where
  the other games draw 640 x 240 for a TV. Its core, `KonamiM2HellNight`, keeps the 384 KB Z buffer in the SDRAM board's memory, with
  a 16 KB Z cache. Its MRA takes the EEPROM and the M48T58 from a split, non-merged or merged set (in a merged one, from
  `evilngt.zip`'s `hellngt/` folder), and sets SOUND VOLUME to 20 of 30, as Evil Night's.
- **Battle Tryst:** its core, `KonamiM2Tryst`, has the Z buffer in the SDRAM board's memory, the CD's data sectors streamed from the
  mounted `btltryst_full.bin` (the data track is 367 MB), compressed texture loads, and the MPEG unit's control, so the game gets past
  its MPEG intro (which shows black).
- **Heat of Eleven '98:** its core, `KonamiM2Heat`, has the Z buffer in the SDRAM board's memory.
- **A freeze after hours, fixed:** the M2 OS's scheduler could run on CPU 2 from its decrementer interrupt and corrupt CPU 1's task
  queue. Battle Tryst and Hell Night froze after hours of attract. CPU 2's decrementer interrupt is now an OSD option, **Off** by
  default (DEC still counts); On is the 602's own behaviour.
- **The triangle engine, closer to MAME:** texels that run on into the next word, the texture blend's 255 − t, the master mode's
  dither off, the minify step within one row. The CPUs' `frsqrte` follows the 602's table.
- **Faster triangle engine and DSP:** the next triangle is set up while one is drawn, a source buffer is read in the pipeline, and
  pixels the clips would throw away aren't walked; the DSP's instructions take fewer clocks.
- **OSD, Advanced page:** *CPU caches* (32 KB, 16 KB, 8 KB, or 4 KB as the 602 itself, each side, at reset; Hell Night's core is fixed
  at 32 KB), *SDRAM read timing* (Normal, Late: for a slow SDRAM module, in the three SDRAM cores), *CPU 2 DEC interrupt* (above).
- **CD audio:** a data read stops the CD audio, as MAME's drive does.
- **Disc files:** `tools/m2disc.py` and the browser converter make Hell Night's, Battle Tryst's and Heat of Eleven's from MAME 0.289's
  CHDs, and from the Redump-based ones that go round.

### Install

1. Unzip `KonamiM2_MiSTer_20261114.zip` over the root of the SD card. It adds four cores to `_Arcade/cores/` and six MRAs to
   `_Arcade/`:

   | Core | MRAs | Needs |
   |---|---|---|
   | `KonamiM2_20261114.rbf` | Tobe! Polystars, Evil Night, Total Vice | |
   | `KonamiM2HellNight_20261114.rbf` | Hell Night | the SDRAM board, any size (32, 64 or 128 MB) |
   | `KonamiM2Tryst_20261114.rbf` | Battle Tryst | the SDRAM board, any size (32, 64 or 128 MB) |
   | `KonamiM2Heat_20261114.rbf` | Heat of Eleven '98 | the SDRAM board, any size (32, 64 or 128 MB) |

2. Make each game's disc files from the CHD in your own MAME 0.289 set. No ROMs or disc images are included. If you have the first
   three games' files from 20261112, keep them.

   | Game | The CHD | Makes |
   |---|---|---|
   | Tobe! Polystars | `polystar/623jaa02.chd` | `polystar_cd.zip`, `polystar_full.bin` (546 MB), `polystar_full.cue` |
   | Evil Night | `evilngt/810uba02.chd` | `evilngt_cd.zip`, `evilngt_full.bin` (515 MB), `evilngt_full.cue` |
   | Total Vice | `totlvice/639eba01.chd` | `totlvice_cd.zip`, `totlvice_full.bin` (522 MB), `totlvice_full.cue` |
   | Hell Night | `hellngt/810eaa02.chd` | `hellngt_cd.zip`, `hellngt_full.bin` (515 MB), `hellngt_full.cue` |
   | Battle Tryst | `btltryst/636jac02.chd` | `btltryst_cd.zip`, `btltryst_full.bin` (423 MB), `btltryst_full.cue` |
   | Heat of Eleven '98 | `heatof11/703eaa02.chd` | `heatof11_cd.zip`, `heatof11_full.bin` (315 MB), `heatof11_full.cue` |

   - **Any of the six, with the repository's `tools/m2disc.py`** (Python 3 and MAME's `chdman`, nothing else), from the folder you
     want the files in, for example:

     ```
     python3 tools/m2disc.py hellngt/810eaa02.chd
     python3 tools/m2disc.py btltryst/636jac02.chd
     python3 tools/m2disc.py heatof11/703eaa02.chd
     ```

     If `chdman` isn't on the PATH, give it after the CHD; on Windows, for example,
     `py tools\m2disc.py btltryst\636jac02.chd C:\mame\chdman.exe`.
   - **Any of the six, in a browser:** the
     [Konami M2 CHD converter](https://konami-m2-chd-converter.fueledmyrrh2.chatgpt.site/); for Polystars, with *Repair gaps in
     Polystars music* ticked. The conversion runs on your computer, and the CHD isn't uploaded.
3. For each game, put your `<set>.zip` and `<set>_cd.zip` in `games/mame/`, and `<set>_full.bin` and `<set>_full.cue` in
   `games/<set>/` (`<set>` is `polystar`, `evilngt`, `totlvice`, `hellngt`, `btltryst` or `heatof11`). Hell Night's set can be
   merged into Evil Night's `evilngt.zip`.
4. Start the game from the Arcade menu. Once for each game, open the OSD and choose its `<set>_full.bin` under *CD audio image*; Main
   remembers it for that game and mounts it at each start. Without it the game runs without its music (and Battle Tryst without its
   data).

The OSD's version line reads `v261114` (Heat of Eleven's core `v261115`), the day the cores were built.

### Video

- **Polystars, Evil Night, Total Vice, Battle Tryst, Heat of Eleven:** 640 x 240 shown on a raster of 857 x 262, 15.56 kHz, 59.39 Hz,
  for a CRT as well as HDMI.
- **Hell Night:** 512 x 384 shown on the arcade monitor's raster of 684 x 416, 24.37 kHz, 58.58 Hz (MAME: 24.76 kHz, 59.51 Hz). A CRT
  for it needs to take 24 kHz.
- **Aspect ratio:** Original, Full Screen and the two custom ratios. **Scale:** Normal, V-Integer, HV-Integer, Narrower HV-Integer,
  HV-Integer+.

### Controls

- **Tobe! Polystars:** a joystick, **Shoot** and **Bomb**, Start and Coin, for two players. The default pad layout: B shoots, A bombs,
  Start, Select for a coin.
- **Battle Tryst:** a joystick, **Guard**, **Punch** and **Kick**, Start and Coin, for two players. The default pad layout: A guards,
  B punches, X kicks, Start, Select for a coin.
- **Heat of Eleven '98:** a joystick, **Pass/Tackle/Lifting**, **Long/Sliding/H.Lift** and **Shift** (named as in the game's guides),
  Start and Coin, for two players. The default pad layout: A, B and X are the three buttons in that order, Start, Select for a coin.
- **Evil Night, Hell Night and Total Vice:** a gun for each player, with **Trigger** and **Reload**, Start and Coin. The default pad
  layout: B is the trigger, A reloads, Start, Select for a coin; in Total Vice, X is *Select (Service)*.

### OSD

CD audio image, Aspect ratio, Scale; for the gun games each player's stick (Auto, Aim, D-pad), the mouse's player and the crosshairs;
Service mode; Advanced: CPU caches, SDRAM read timing, CPU 2 DEC interrupt; DIP Switches (Sound Output and Flip Screen; Evil Night and
Hell Night only Flip Screen; none for Battle Tryst and Heat of Eleven), Reset.

### Checked

- **On a real MiSTer:** the repository owner played Hell Night, Battle Tryst and Heat of Eleven '98 on this release's cores, with the
  SDRAM board, as Tobe! Polystars, Evil Night and Total Vice before them. By tallendorf, on a MiSTerPi, a MultiSystem 2 and a DE10-Nano with the SDRAM board:
  Hell Night and Heat of Eleven '98 played, a Battle Tryst match played; Hell Night's attract for 10 h without a freeze, and Battle
  Tryst's for 17.2 h and 16.6 h on a debug build forcing CPU 2's decrementer every half second, with the OSD's gate.
- **In simulation** (Verilator): the triangle engine's writes on the lists dumped from Polystars, Evil Night and Total Vice, byte for
  byte as before or closer to MAME, never further; the video timing, the BDA and the video unit of the first three games' core
  clock for clock the same as before Hell Night's raster was added; the boot to the attract mode; the CPUs against a reference model
  with random programs and interrupts.
- **The disc files:** MAME 0.289's own CHDs of Hell Night, Battle Tryst and Heat of Eleven give the same data sectors as the
  Redump-based CHDs the games were tested with. From those CHDs the browser converter's files are byte for byte `tools/m2disc.py`'s.
- **Quartus 17.0.2:** each core's timing met on every clock (the slack on the worst path):

  | Core | ALMs (of 41,910) | Machine, 66.67 MHz | SDRAM, 133.33 MHz | HDMI |
  |---|---|---|---|---|
  | `KonamiM2` | 38,761 (92 %) | +1.152 ns | | +0.407 ns |
  | `KonamiM2HellNight` | 41,439 (99 %) | +0.603 ns | +0.111 ns | +0.073 ns |
  | `KonamiM2Tryst` | 41,396 (99 %) | +0.592 ns | +0.148 ns | +0.146 ns |
  | `KonamiM2Heat` | 40,223 (96 %) | +0.881 ns | +0.591 ns | +0.356 ns |

### Known differences / open points

- **Speed:** in Polystars, where the real board slows down, the core slows down less. The other games haven't been timed against a
  real board. Hell Night's continue screen (its 10 s take about 17) and Battle Tryst's character select (about a third of its speed)
  run slow; Battle Tryst's matches are close to full speed. Hell Night's frame rate is 58.6 Hz, MAME's 59.5 Hz.
- **The SDRAM cores:** on the bench, with the Z buffer in SDRAM, a few pixels of some pictures take another pixel's colour. Not yet
  fixed.
- **MPEG:** the 3DO M2's MPEG video decoder isn't in the core: Battle Tryst's intro is black.
- **Games:** all six of MAME's Konami M2 games are supported. Total Vice's other sets, JAD, AAB and UAC, are marked not working in
  MAME 0.289 and aren't supported. MAME marks Battle Tryst and Heat of Eleven '98 as preliminary; its Battle Tryst stops at the MPEG
  intro, which the core gets past.
- No CRT Adjust and no Scandoubler Fx yet. The volume is each game's own, in its service menu.

### Credits

MAME (the konamim2 driver and the 3DO M2 devices by Phil Bennett, the PowerPC core by Aaron Giles and R. Belmont, the YMZ280B by Aaron
Giles), tallendorf (Hell Night's, Battle Tryst's and Heat of Eleven's cores, the CPU 2 decrementer fix, the triangle engine's and DSP's
accuracy and speed, the CPU cache option, the single-precision float units, `tools/build.py`), the repository owner's Slap Shot core
(the light guns), the repository owner's Gaelco 3D core (the platform layer, the base of the Z buffer in the SDRAM, the benches, the
packaging), and the MiSTer framework.
