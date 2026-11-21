## Konami M2 for MiSTer - 20261121

Konami's **M2** arcade board (1997-1998), the 3DO M2 hardware: two PowerPC 602s at 66.67 MHz, a triangle engine, an audio DSP and a CD
drive. Six MRAs and four cores: **Tobe! Polystars** (ver JAA, 1997), the light-gun games **Evil Night** (ver UBA, 1998), **Hell Night**
(ver EAA, 1998) and **Total Vice** (ver EBA, 1997), the fighting game **Battle Tryst** (ver JAC, 1998) and the football game **Heat of
Eleven '98** (ver EAA, 1998).

**Two picture fixes.** Polystars' attract no longer flashes a pixel at its lower left, and on the SDRAM board's cores no pixel takes
another pixel's colour. Everything else is as in 20261119, at the same speed.

### What's new

- **The flashing pixel in Polystars:** in 20261119, a pixel at the lower left of the attract mode's picture flashed black or white.
  The core counted the video lines as MAME 0.289 does, 20 lines early. The M2's OS reads that count to know when the picture it has
  shown has been read out, and the game then clears that buffer for its next picture: with the count early, the clear began while
  the picture's last rows were still being shown, and its first pixel is the last row's left end. The count is now the line the
  display reads, as the M2 OS's own display code works it out, in all four cores. Every game's line interrupts now come where its OS
  asks for them.
- **The SDRAM board's cores** (Hell Night, Battle Tryst, Heat of Eleven '98): a few pixels of some pictures took another pixel's
  colour. In a thin triangle, two pixels of different rows could reach the texture stage back to back, and the texture's detail level
  was then worked out across them, turning filtering on where it should be off. Each pixel now carries its own mark for the start of
  its row's span.

### Install

1. Unzip `KonamiM2_MiSTer_20261121.zip` over the root of the SD card:

   | On the SD card | What |
   |---|---|
   | `_Arcade/cores/KonamiM2_20261121.rbf` | Tobe! Polystars, Evil Night, Total Vice |
   | `_Arcade/cores/KonamiM2HellNight_20261121.rbf` | Hell Night; needs the SDRAM board, any size (32, 64 or 128 MB) |
   | `_Arcade/cores/KonamiM2Tryst_20261121.rbf` | Battle Tryst; needs the SDRAM board |
   | `_Arcade/cores/KonamiM2Heat_20261121.rbf` | Heat of Eleven '98; needs the SDRAM board |
   | `_Arcade/<game>.mra` | the six MRAs, each asking for its core above |
   | `m2mpegd/m2mpegd` | Battle Tryst's movies' decoder |
   | `m2mpegd/m2mpegd_service.sh` | starts and stops it |
   | `m2mpegd/m2_mem_wc-5.15.1-MiSTer.ko`, `m2_mem_wc-6.18.38-MiSTer.ko` | a kernel module for a faster picture copy, for each of these MiSTer kernels; on another kernel the movies still play |
   | `Scripts/m2mpegd_autostart_on.sh`, `Scripts/m2mpegd_autostart_off.sh` | turn starting the decoder at boot on and off |

   **From 20261119:** only the four cores are new (the MRAs differ only in a comment: the converter's address). Delete the four
   `_20261119.rbf` cores from `_Arcade/cores/`. The decoder, its scripts, the disc files and your saves stay as they are.
2. **For Battle Tryst's movies:** run **m2mpegd_autostart_on** from Scripts once: it starts the decoder, and from then on it
   starts at every boot. **m2mpegd_autostart_off** turns it off. Each script goes back to the menu by itself a few seconds after
   it's done. With only a CRT connected, MiSTer shows a notice about `MiSTer.ini` while a script runs: that's normal, wait for the
   menu to come back. If you turned it on for 20261119, it's still on.
3. The disc files are as in 20261114 and 20261119: if you have them, keep them. Otherwise make each game's from the CHD in your own
   MAME 0.289 set. No ROMs or disc images are included.

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

The OSD's version line reads `v261121`, the day the cores were built.

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
  layout: B is the trigger, A reloads, Start, Select for a coin; in Total Vice, X is *Select (Service)*. Each player's Input is
  **Controller** (the default, with a crosshair), **Mouse**, **Sinden** or **Light gun**.
- **Every game:** **Pause** (R) and **Step** (L).

### OSD

CD audio image, Aspect ratio, Scale; CRT Adjust (page); for the gun games each player's Input and, for the Inputs in use, Controller
stick, Crosshair, Sinden border and Off-screen edge; Service mode; Pause when OSD is open; Advanced: CPU caches, SDRAM read timing, CPU
2 DEC interrupt; DIP Switches (Sound Output and Flip Screen; Evil Night and Hell Night only Flip Screen; none for Battle Tryst and Heat
of Eleven), Reset.

### Checked

- **On a real MiSTer:** this release's own four cores, with Polystars' attract showing no flashing pixel; on test builds, Hell
  Night, Battle Tryst and Heat of Eleven '98 played with the SDRAM board's colour fix (its few wrong pixels are too rare to watch
  for: the bench shows them).
- **In simulation:** Polystars on the whole machine for 1,168 frames: its clear never writes a row of the picture being shown before
  the display has read it (without the fix, in 50 of the frames it did). The line count against the M2 OS's display code, followed in
  MAME's debugger: the OS takes picture line p to the count p + 24 in Polystars, the lines its display list has before the picture.
  The triangle engine's writes with the Z buffer in SDRAM, byte for byte those with it on the chip, on all nine sets of lists dumped
  from the games.
- **The files:** the four cores are the ones tested on the board, byte for byte, built from this release's tree; `m2mpegd` and its
  scripts are 20261119's, byte for byte.
- **Quartus 17.0.2:** each core's timing met on every clock (the slack on the worst path):

  | Core | ALMs (of 41,910) | Machine, 66.67 MHz | SDRAM, 133.33 MHz | HDMI |
  |---|---|---|---|---|
  | `KonamiM2` | 36,968 (88 %) | +1.505 ns | | +0.380 ns |
  | `KonamiM2HellNight` | 37,926 (90 %) | +1.309 ns | +0.227 ns | +0.290 ns |
  | `KonamiM2Tryst` | 40,046 (96 %) | +0.285 ns | +0.229 ns | +0.621 ns |
  | `KonamiM2Heat` | 36,470 (87 %) | +1.221 ns | +0.422 ns | +0.401 ns |

### Known differences / open points

- **Speed:** Polystars ran stage 3 at 112 % of the real board's speed on release 20261110's core; where the board slows down, the
  core slows down less. The other games haven't been timed against a real board. Hell Night's continue screen (its 10 s take about
  14) and Battle Tryst's character select (about a third of its speed in 20261114) run slow; Battle Tryst's matches are close to full
  speed.
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
