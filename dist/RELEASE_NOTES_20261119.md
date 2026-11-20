## Konami M2 for MiSTer - 20261119

Konami's **M2** arcade board (1997-1998), the 3DO M2 hardware: two PowerPC 602s at 66.67 MHz, a triangle engine, an audio DSP and a CD
drive. Six MRAs and four cores: **Tobe! Polystars** (ver JAA, 1997), the light-gun games **Evil Night** (ver UBA, 1998), **Hell Night**
(ver EAA, 1998) and **Total Vice** (ver EBA, 1997), the fighting game **Battle Tryst** (ver JAC, 1998) and the football game **Heat of
Eleven '98** (ver EAA, 1998).

**Battle Tryst's movies, CRT Adjust, and a new gun setup.** Battle Tryst now plays its intro and attract movies, decoded on the
MiSTer's ARM by tallendorf's `m2mpegd`. Every core has rmonic79's CRT Adjust, Hell Night's 24 kHz one too. In the gun games each
player picks what they aim with, and the OSD shows only the settings that matter for it.

### What's new

- **Battle Tryst's movies:** the M2's MPEG unit has its registers in the FPGA and hands each picture to `m2mpegd`, a decoder on the
  MiSTer's ARM, which writes it back into game RAM, as NDS4MiSTer and DreamSTer do. It's in the release zip, and is turned on once
  from Scripts (Install, below). While another core runs it sleeps, waking once a second to see which core is loaded; it serves only
  Battle Tryst's core. Without it the game plays as before, with its movies black.
- **CRT Adjust** (rmonic79's, in all four cores): H-Size, H-Position and V-Shift for an analog CRT, on its own OSD page. The picture
  is sized and moved through a line buffer while the sync keeps its timing, so the monitor stays locked. H-Position stops where the
  picture would reach into the hsync pulse or past the line's end, so a line is never cut. Off, the picture is exactly as before.
- **Gun games, one Input per player:** P1, P2 and P3 Input are **Controller** (the default: the pad's stick and d-pad, with a
  crosshair), **Mouse**, **Sinden** or **Light gun** (GUN4IR and the like). Controller stick (Position, Move), Crosshair, Sinden
  border and Off-screen edge show only when an Input uses them. A crosshair shows once its player has aimed or fired.
- **Sinden light guns:** the core draws the white border a Sinden needs (16, 24 or 8 px) while a player's Input is Sinden.
- **Pause and Step** (every game; R and L on the pad): Player 1's Pause holds the machine and the sound; while paused, Step runs one
  frame, for screenshots. *Pause when OSD is open* in the OSD.
- **The M48T58:** the board's battery-backed RAM and clock (Battle Tryst, Heat of Eleven, Evil Night, Hell Night). Its 8 KB is saved
  with the EEPROM in the same file in `config/nvram/`, and the clock starts from the MiSTer's. A save from 20261114 keeps its EEPROM
  settings.
- **The CPUs as a 602:** a float result 3 clocks after its instruction (it was 5 or 8), as timed on a Panasonic FZ-35S, a retail M2;
  the instructions a 602 doesn't have go to its emulation trap, as on the chip.
- **The triangle engine's blender as on a real M2:** dither, the 5-bit ALU select and the source alpha clamp, measured with test
  lists on a Panasonic FZ-35S. Its colour cache now reads and writes ahead of the pixels, and Battle Tryst's core has its faster
  compressed texture loads back.
- **Hell Night:** a 64 KB Z cache (it was 16 KB): its continue screen's 10 s take about 14 (about 20 before). Its raster has a
  673-pixel line, 24.77 kHz and 59.53 Hz, MAME's rates within 0.1 %; before it ran 1.6 % slow.

### Install

1. Unzip `KonamiM2_MiSTer_20261119.zip` over the root of the SD card:

   | On the SD card | What |
   |---|---|
   | `_Arcade/cores/KonamiM2_20261119.rbf` | Tobe! Polystars, Evil Night, Total Vice |
   | `_Arcade/cores/KonamiM2HellNight_20261119.rbf` | Hell Night; needs the SDRAM board, any size (32, 64 or 128 MB) |
   | `_Arcade/cores/KonamiM2Tryst_20261119.rbf` | Battle Tryst; needs the SDRAM board |
   | `_Arcade/cores/KonamiM2Heat_20261119.rbf` | Heat of Eleven '98; needs the SDRAM board |
   | `_Arcade/<game>.mra` | the six MRAs, each asking for its core above |
   | `m2mpegd/m2mpegd` | Battle Tryst's movies' decoder |
   | `m2mpegd/m2mpegd_service.sh` | starts and stops it |
   | `m2mpegd/m2_mem_wc-5.15.1-MiSTer.ko`, `m2_mem_wc-6.18.38-MiSTer.ko` | a kernel module for a faster picture copy, for each of these MiSTer kernels; on another kernel the movies still play |
   | `Scripts/m2mpegd_autostart_on.sh`, `Scripts/m2mpegd_autostart_off.sh` | turn starting the decoder at boot on and off |

2. **For Battle Tryst's movies:** run **m2mpegd_autostart_on** from Scripts once: it starts the decoder, and from then on it
   starts at every boot. **m2mpegd_autostart_off** turns it off. Each script goes back to the menu by itself a few seconds after
   it's done. With only a CRT connected, MiSTer shows a notice about `MiSTer.ini` while a script runs: that's normal, wait for the
   menu to come back.
3. The disc files are as in 20261114: if you have them, keep them. Otherwise make each game's from the CHD in your own MAME 0.289
   set. No ROMs or disc images are included.

   | Game | The CHD | Makes |
   |---|---|---|
   | Tobe! Polystars | `polystar/623jaa02.chd` | `polystar_cd.zip`, `polystar_full.bin` (546 MB), `polystar_full.cue` |
   | Evil Night | `evilngt/810uba02.chd` | `evilngt_cd.zip`, `evilngt_full.bin` (515 MB), `evilngt_full.cue` |
   | Total Vice | `totlvice/639eba01.chd` | `totlvice_cd.zip`, `totlvice_full.bin` (522 MB), `totlvice_full.cue` |
   | Hell Night | `hellngt/810eaa02.chd` | `hellngt_cd.zip`, `hellngt_full.bin` (515 MB), `hellngt_full.cue` |
   | Battle Tryst | `btltryst/636jac02.chd` | `btltryst_cd.zip`, `btltryst_full.bin` (423 MB), `btltryst_full.cue` |
   | Heat of Eleven '98 | `heatof11/703eaa02.chd` | `heatof11_cd.zip`, `heatof11_full.bin` (315 MB), `heatof11_full.cue` |

   - **Any of the six, in a browser:** the
     [Konami M2 CHD converter](https://decoryah.github.io/konami-m2-chd-converter/); for Polystars, with *Repair gaps in
     Polystars music* ticked. The conversion runs on your computer, and the CHD isn't uploaded.
   - **Or with the repository's `tools/m2disc.py`** (Python 3 and MAME's `chdman`, nothing else), from the folder you want the files
     in, for example `python3 tools/m2disc.py btltryst/636jac02.chd`. If `chdman` isn't on the PATH, give it after the CHD; on
     Windows, for example, `py tools\m2disc.py btltryst\636jac02.chd C:\mame\chdman.exe`.
4. For each game, put your `<set>.zip` and `<set>_cd.zip` in `games/mame/`, and `<set>_full.bin` and `<set>_full.cue` in
   `games/<set>/` (`<set>` is `polystar`, `evilngt`, `totlvice`, `hellngt`, `btltryst` or `heatof11`). Hell Night's set can be
   merged into Evil Night's `evilngt.zip`.
5. Start the game from the Arcade menu. Once for each game, open the OSD and choose its `<set>_full.bin` under *CD audio image*; Main
   remembers it for that game and mounts it at each start. Without it the game runs without its music (and Battle Tryst without its
   data).

The OSD's version line reads `v261119`, the day the cores were built.

### Video

- **Polystars, Evil Night, Total Vice, Battle Tryst, Heat of Eleven:** 640 x 240 shown on a raster of 857 x 262, 15.56 kHz, 59.39 Hz,
  for a CRT as well as HDMI.
- **Hell Night:** 512 x 384 shown on the arcade monitor's raster of 673 x 416, 24.77 kHz, 59.53 Hz (MAME: 24.76 kHz, 59.51 Hz). A CRT
  for it needs to take 24 kHz.
- **Aspect ratio:** Original, Full Screen and the two custom ratios. **Scale:** Normal, V-Integer, HV-Integer, Narrower HV-Integer,
  HV-Integer+. **CRT Adjust:** Off, On; H-Size 0 to +5 and -16 to -1, H-Position -48 to +16 (in steps of 2 pixels), V-Shift -16 to
  +15.

### Controls

- **Tobe! Polystars:** a joystick, **Shoot** and **Bomb**, Start and Coin, for two players. The default pad layout: B shoots, A bombs,
  Start, Select for a coin.
- **Battle Tryst:** a joystick, **Guard**, **Punch** and **Kick**, Start and Coin, for two players. The default pad layout: A guards,
  B punches, X kicks, Start, Select for a coin.
- **Heat of Eleven '98:** a joystick, **Pass/Tackle/Lifting**, **Long/Sliding/H.Lift** and **Shift** (named as in the game's guides),
  Start and Coin, for two players. The default pad layout: A, B and X are the three buttons in that order, Start, Select for a coin.
- **Evil Night, Hell Night and Total Vice:** a gun for each player, with **Trigger** and **Reload**, Start and Coin. The default pad
  layout: B is the trigger, A reloads, Start, Select for a coin; in Total Vice, X is *Select (Service)*.
- **Every game:** **Pause** (R) and **Step** (L).

### OSD

CD audio image, Aspect ratio, Scale; CRT Adjust (page); for the gun games each player's Input and, for the Inputs in use, Controller
stick, Crosshair, Sinden border and Off-screen edge; Service mode; Pause when OSD is open; Advanced: CPU caches, SDRAM read timing, CPU
2 DEC interrupt; DIP Switches (Sound Output and Flip Screen; Evil Night and Hell Night only Flip Screen; none for Battle Tryst and Heat
of Eleven), Reset.

### Checked

- **On a real MiSTer:** the repository owner tested all of tallendorf's changes in this release together on his last test build, the
  gun games' Input settings, Battle Tryst's movies with `m2mpegd` and its auto-start scripts, and, on this release's own cores, CRT
  Adjust on a CRT. By tallendorf, on a MiSTerPi (kernel 5.15.1) and a DE10-Nano (6.18.38), both with the SDRAM board: Battle Tryst's
  intro and attract movies looped, watched for tears and sound, none seen; the DE10-Nano ran the decoder overnight, 27,404 pictures,
  none late, no errors.
- **In simulation:** CRT Adjust on both rasters (On at 0 / 0 / 0 the same picture in the same place as Off; every H-Size at every
  H-Position keeps each line whole, after the hsync pulse and inside the line; V-Shift by whole lines); the triangle engine's writes on
  the lists dumped from Polystars, byte for byte MAME's; the 3-clock float pipeline on 2,000,000 random operations in every rounding
  mode against IEEE floats; the movies' decoder through the core's MPEG unit against the M2 emulator's pictures.
- **The files:** the four cores are the ones tested on the board for CRT Adjust, built from this release's tree; `m2mpegd` and its
  scripts are the ones tested on the board, byte for byte.
- **Quartus 17.0.2:** each core's timing met on every clock (the slack on the worst path):

  | Core | ALMs (of 41,910) | Machine, 66.67 MHz | SDRAM, 133.33 MHz | HDMI |
  |---|---|---|---|---|
  | `KonamiM2` | 36,992 (88 %) | +1.616 ns | | +0.367 ns |
  | `KonamiM2HellNight` | 38,179 (91 %) | +0.737 ns | +0.262 ns | +0.335 ns |
  | `KonamiM2Tryst` | 39,850 (95 %) | +0.674 ns | +0.407 ns | +0.560 ns |
  | `KonamiM2Heat` | 36,380 (87 %) | +1.300 ns | +0.160 ns | +0.236 ns |

### Known differences / open points

- **Speed:** Polystars ran stage 3 at 112 % of the real board's speed on release 20261110's core; where the board slows down, the
  core slows down less. The other games haven't been timed against a real board. Hell Night's continue screen (its 10 s take about
  14) and Battle Tryst's character select (about a third of its speed in 20261114) run slow; Battle Tryst's matches are close to full
  speed.
- **The SDRAM cores:** on the bench, with the Z buffer in SDRAM, a few pixels of some pictures take another pixel's colour. Not yet
  fixed.
- **Battle Tryst's movies** need `m2mpegd` running on the ARM (Install, step 2); without it they're black.
- **Games:** all six of MAME's Konami M2 games are supported. Total Vice's other sets, JAD, AAB and UAC, are marked not working in
  MAME 0.289 and aren't supported. MAME marks Battle Tryst and Heat of Eleven '98 as preliminary; its Battle Tryst stops at the MPEG
  intro, which the core gets past.
- No Scandoubler Fx yet. The volume is each game's own, in its service menu.

### Credits

MAME (the konamim2 driver and the 3DO M2 devices by Phil Bennett, the PowerPC core by Aaron Giles and R. Belmont, the YMZ280B by Aaron
Giles), tallendorf (Hell Night's, Battle Tryst's and Heat of Eleven's cores, Battle Tryst's movies with `m2mpegd` and its kernel
module, the CPUs as a 602, the triangle engine's blender as measured on a real M2, Pause and Step, Sinden guns, the M48T58, the CPU 2
decrementer fix, the triangle engine's and DSP's accuracy and speed, the CPU cache option, the single-precision float units,
`tools/build.py`), rmonic79 (Umberto Parisi) with Andrea Bogazzi (asturur) (CRT Adjust), NDS4MiSTer's `nds_mem_wc` and DreamSTer (the
kernel module's write-combined mapping), the repository owner's Slap Shot core (the light guns), the repository owner's Gaelco 3D core
(the platform layer, the base of the Z buffer in the SDRAM, the benches, the packaging), and the MiSTer framework.
