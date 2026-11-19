# Konami M2 for MiSTer

A MiSTer FPGA core for Konami's M2 arcade board (1997-1998), the 3DO M2 hardware of MAME's `konami/konamim2.cpp` driver. It runs
**Tobe! Polystars** (`polystar`), Konami's 3D shooter, the light-gun games **Evil Night** (`evilngt`), its European version **Hell
Night** (`hellngt`) and **Total Vice** (`totlvice`), the fighting game **Battle Tryst** (`btltryst`) and the football game **Heat of
Eleven '98** (`heatof11`): two PowerPC 602s at 66.67 MHz, the BDA (memory controller, triangle engine, video, audio DSP), the CDE (the
CD drive's ATAPI bus) and Konami's I/O, with each game's program and data on a CD; for the gun games also their YMZ280B sample chip and
the light guns. Hell Night, Battle Tryst and Heat of Eleven each have their own build, with the Z buffer in the SDRAM board's memory.
Written from MAME 0.289's driver and its `3dom2.cpp` / `3dom2_te.cpp` devices, with MAME as the reference; the platform layer and the
way each block is checked follow the owner's Gaelco 3D core, and the SDRAM builds' Z buffer is based on it.

<p align="center">
  <b>Tobe! Polystars</b><br>
  <img src="docs/images/title.png" width="400" alt="Tobe! Polystars' title screen">
  <img src="docs/images/gameplay.png" width="400" alt="Stage 1 of Tobe! Polystars">
</p>

<p align="center">
  <b>Evil Night</b><br>
  <img src="docs/images/evilngt_title.png" width="400" alt="Evil Night's title screen">
  <img src="docs/images/evilngt_gameplay.png" width="400" alt="Evil Night: a skeleton on the mansion's stairs">
</p>

<p align="center">
  <b>Total Vice</b><br>
  <img src="docs/images/totlvice_title.png" width="400" alt="Total Vice's title screen">
  <img src="docs/images/totlvice_gameplay.png" width="400" alt="Total Vice: a supermarket, with VIOLENT MODE at BLOODY">
</p>

<p align="center">
  <b>Hell Night</b><br>
  <img src="docs/images/hellngt_title.png" width="400" alt="Hell Night's title screen">
  <img src="docs/images/hellngt_gameplay.png" width="400" alt="Hell Night: a zombie in the mansion's corridor">
</p>

<p align="center">
  <b>Battle Tryst</b><br>
  <img src="docs/images/btltryst_title.png" width="400" alt="Battle Tryst's title screen">
  <img src="docs/images/btltryst_gameplay.png" width="400" alt="Battle Tryst: Bites against Zankoku in stage 1">
</p>

<p align="center">
  <b>Heat of Eleven '98</b><br>
  <img src="docs/images/heatof11_title.png" width="400" alt="Heat of Eleven '98's title screen">
  <img src="docs/images/heatof11_gameplay.png" width="400" alt="Heat of Eleven '98: Brazil against Scotland">
</p>

Battle Tryst's pictures are screenshots from a MiSTer; the others are from MAME 0.289.

No ROMs or CD images are in this repository; you supply your own MAME sets.

**Status.** All six games are supported, tested and working on a real MiSTer, with their music and sound effects: every game of
MAME's Konami M2 driver, Total Vice in its EBA version. The owner has played Tobe! Polystars through, more than once, and has played
Evil Night, Total Vice, Hell Night, Battle Tryst and Heat of Eleven '98; tallendorf has played the last three too, and left Battle
Tryst's and Hell Night's attract running for hours without a freeze.
**Polystars runs at full speed:** stage 3, timed against a video of the real board, takes 154.8 s where the board takes 173.6 s (112 %
of its speed; 110 % before the lava, 133 % in it, 106 % after). Where the real board slows down, the core slows down less. The other
games' speed hasn't been timed against a real board; Hell Night's continue screen and Battle Tryst's character select are known to run
slow (see Notes).
Built with Quartus 17.0, each core's timing met on every clock (the slack on the worst path):

| Core | ALMs (of 41,910) | Machine, 66.67 MHz | SDRAM, 133.33 MHz | HDMI |
|---|---|---|---|---|
| `KonamiM2` | 38,761 (92 %) | +1.152 ns | | +0.407 ns |
| `KonamiM2HellNight` | 41,439 (99 %) | +0.603 ns | +0.111 ns | +0.073 ns |
| `KonamiM2Tryst` | 41,396 (99 %) | +0.592 ns | +0.148 ns | +0.146 ns |
| `KonamiM2Heat` | 40,223 (96 %) | +0.881 ns | +0.591 ns | +0.356 ns |

| Game | Set | On this core |
|---|---|---|
| Tobe! Polystars (ver JAA, 1997) | `polystar` | plays, at full speed |
| Evil Night (ver UBA, 1998) | `evilngt` | plays: light guns, up to three players |
| Total Vice (ver EBA, 1997) | `totlvice` | plays: light guns, up to two players |
| Hell Night (ver EAA, 1998) | `hellngt` | plays: light guns, up to three players, on the arcade monitor's 512 x 384; its own build (`KonamiM2HellNight`), needs the SDRAM board |
| Battle Tryst (ver JAC, 1998) | `btltryst` | plays, close to full speed in a match; its movies with the ARM's decoder (below); its own build (`KonamiM2Tryst`), needs the SDRAM board |
| Heat of Eleven '98 (ver EAA, 1998) | `heatof11` | plays; its own build (`KonamiM2Heat`), needs the SDRAM board |
| Total Vice (ver JAD, AAB, UAC, 1997) | `totlvicj`, `totlvica`, `totlvicu` | not supported: not working in MAME 0.289 |

## Install

1. Unzip `KonamiM2_MiSTer_<date>.zip` (`tools/package.py` writes it to `dist/`) over the root of the SD card (`/media/fat/`): the four
   cores go to `_Arcade/cores/`, the six MRAs to `_Arcade/`. Each MRA asks for its core by name:

   | Core | MRAs | Needs |
   |---|---|---|
   | `KonamiM2_<date>.rbf` | Tobe! Polystars, Evil Night, Total Vice | |
   | `KonamiM2HellNight_<date>.rbf` | Hell Night | the SDRAM board |
   | `KonamiM2Tryst_<date>.rbf` | Battle Tryst | the SDRAM board |
   | `KonamiM2Heat_<date>.rbf` | Heat of Eleven '98 | the SDRAM board |

   By hand from the repository: `releases/<core>_<date>.rbf` to `_Arcade/cores/`, `mra/*.mra` to `_Arcade/`. Hell Night, Battle Tryst
   and Heat of Eleven keep their Z buffer in the SDRAM board's memory (any size: it uses the first 32 MB).
2. Make each game's disc files from the CHD in your MAME 0.289 set. They aren't in a MAME set: `<set>_cd.zip` holds the disc's data
   track, which the core loads with the game, and `<set>_full.bin` the whole disc, from which it plays the music.

   | Game | The CHD | Makes |
   |---|---|---|
   | Tobe! Polystars | `polystar/623jaa02.chd` | `polystar_cd.zip` (24 MB in it), `polystar_full.bin` (546 MB), `polystar_full.cue` |
   | Evil Night | `evilngt/810uba02.chd` | `evilngt_cd.zip` (58 MB in it), `evilngt_full.bin` (515 MB), `evilngt_full.cue` |
   | Total Vice | `totlvice/639eba01.chd` | `totlvice_cd.zip` (42 MB in it), `totlvice_full.bin` (522 MB), `totlvice_full.cue` |
   | Hell Night | `hellngt/810eaa02.chd` | `hellngt_cd.zip` (58 MB in it), `hellngt_full.bin` (515 MB), `hellngt_full.cue` |
   | Battle Tryst | `btltryst/636jac02.chd` | `btltryst_cd.zip` (2 KB in it: the data sectors stream from `btltryst_full.bin`), `btltryst_full.bin` (423 MB), `btltryst_full.cue` |
   | Heat of Eleven '98 | `heatof11/703eaa02.chd` | `heatof11_cd.zip` (25 MB in it), `heatof11_full.bin` (315 MB), `heatof11_full.cue` |

   The `.cue` is the image's cue sheet; the core doesn't need it. Make them in either of these ways:

   - **Any of these, with this repository's `tools/m2disc.py`** (Python 3 and MAME's `chdman`, nothing else). From the folder you
     want the files in:

     ```
     python3 tools/m2disc.py polystar/623jaa02.chd
     python3 tools/m2disc.py evilngt/810uba02.chd
     python3 tools/m2disc.py totlvice/639eba01.chd
     python3 tools/m2disc.py hellngt/810eaa02.chd
     python3 tools/m2disc.py btltryst/636jac02.chd
     python3 tools/m2disc.py heatof11/703eaa02.chd
     ```

     `chdman` comes with MAME. If it isn't on the PATH, give it after the CHD; on Windows, for example,
     `py tools\m2disc.py totlvice\639eba01.chd C:\mame\chdman.exe`. The tool knows each disc by its tracks and checks its data, and
     says so if a CHD is none of these or another version of the game: Total Vice's AAB, JAD and UAC discs have the same tracks,
     and the core runs only EBA's. Total Vice's CHD keeps its data track as 2048-byte sectors, and the core finds the music by 2352-byte
     ones, so the tool pads that track in `totlvice_full.bin`; it does the same for an older Polystars CHD kept that way. Polystars'
     music it also repairs (below). Hell Night, Battle Tryst and Heat of Eleven are checked on their data sectors alone, as CHDs
     of their discs go round with the 2 s before the music kept in different ways; each is laid out as on the disc.
   - **Any of the six, in a browser:** choose the CHD in the [Konami M2 CHD converter](https://konami-m2-chd-converter.fueledmyrrh2.chatgpt.site/)
     (for Polystars, keep *Repair gaps in Polystars music* ticked) and download the three files it makes. The conversion runs on your
     computer, and the CHD isn't uploaded. It needs a desktop browser (Chrome or Edge) and about 2 GB of free memory.

   **Polystars' music:** MAME marks `623jaa02.chd` as a bad dump: its music has 28 stretches of 0.35 s of silence, where the ripper's
   reads failed, 16 of them in the stage 7 boss's music. On the board they're short gaps in the music. Both ways above fill each from
   the same music elsewhere in its track (the music repeats). A `polystar_full.bin` made before, without the repair, is repaired in
   place by `python3 tools/cdfix.py polystar_full.bin`, which checks the file first and leaves alone one that isn't this image or is
   already repaired. The repair holds only positions; all the audio comes from your image. Evil Night's and Total Vice's CHDs have no
   such gaps.
3. Put the files on the SD card, for each game (`<set>` is `polystar`, `evilngt`, `totlvice`, `hellngt`, `btltryst` or `heatof11`):

   | File | Goes in |
   |---|---|
   | `<set>.zip` (your MAME 0.289 set) and `<set>_cd.zip` | `/media/fat/games/mame/` |
   | `<set>_full.bin` and `<set>_full.cue` | `/media/fat/games/<set>/`, for example `/media/fat/games/totlvice/` |

4. Start the game from the Arcade menu. Once for each game, open the OSD and choose its `<set>_full.bin` under *CD audio image*; Main
   remembers it for that game and mounts it at each start. (The MRA also asks for it, but Main releases up to 20261010 don't act on
   that.) Without it the game runs without its music.

## Battle Tryst's movies (MPEG)

For its MPEG video, Battle Tryst's build is a hybrid, as NDS4MiSTer and DreamSTer are: the FPGA has the M2 MPEG unit's
registers and passes each picture's data to a helper on the MiSTer's ARM, `m2mpegd`, which decodes it and writes the picture
back into game RAM. Without `m2mpegd` running, the game plays normally but its movies (the intro and the attract's scenes)
are black.

### Install

From the release, `m2mpegd_<date>.zip` holds two folders; copy both to the root of the SD card (`/media/fat`):

| On the SD card | What |
|---|---|
| `m2mpegd/m2mpegd` | the decoder |
| `m2mpegd/m2mpegd_service.sh` | starts and stops it |
| `m2mpegd/m2_mem_wc-<kernel>.ko` | an optional kernel module for a faster picture copy, one per MiSTer kernel |
| `Scripts/m2mpegd_autostart_on.sh` | turns starting the decoder at boot on |
| `Scripts/m2mpegd_autostart_off.sh` | turns it off |

The Battle Tryst MRA and RBF go where they always do (Install, above).

### Turning it on

Run `m2mpegd_autostart_on` from Scripts once. It adds a line to `/media/fat/linux/user-startup.sh` (a backup of the file is
kept as `user-startup.sh.bak_m2mpegd`) and starts the decoder; from then on it starts at every boot. Battle Tryst then plays
its movies however it's loaded, from any MRA in any folder: the decoder goes by the core's name (`btltryst`, the MRA's set
name), not by a file's path. `m2mpegd_autostart_off` removes the line and stops the decoder. Running either one again
changes nothing.

Each script goes back to the menu by itself a few seconds after it's done (the menu reloads, as when you leave a core); a
button press goes back sooner. With only a CRT connected and no scaler on it, MiSTer shows a notice about `MiSTer.ini`
instead of a script's text while any script runs. That's normal: wait for the menu to come back.

- **What it costs while another core runs:** nothing you'd notice. The decoder sleeps, at normal priority, wakes once a
  second to read which core is loaded (a file in RAM), and touches no other memory. The FPGA cores don't run on the ARM.
- **While Battle Tryst runs:** it decodes each picture on both ARM cores, at raised priority, and goes back to sleep when
  another core is loaded.
- **It never writes into another core's memory:** it starts only when the loaded core is Battle Tryst's and that core's MPEG
  block in DDR3 is there and moving.

The decoder's messages go to `/tmp/m2mpegd.log` (in RAM, nothing is written to the SD card).

### How it works

- Each picture is decoded on both ARM cores and copied into game RAM 22 ms after its data arrives. The game redraws the movie
  from game RAM every frame, so a copy at a fixed point in the frame stays clear of that read; without the delay the movie
  tears.
- The kernel module maps game RAM write-combined, the same way NDS4MiSTer's `nds_mem_wc` does (the idea is from DreamSTer):
  a picture's copy takes about 0.3-0.5 ms instead of 3.7. It's built for one kernel; `m2mpegd_service.sh` loads the one
  that matches `uname -r`. With no match (a newer MiSTer kernel than the release knows), it says so in the log and the
  decoder copies through `/dev/mem` as before: the movies still play.
- `m2mpegd` is a plain MPEG-1 video decoder (ISO 11172-2): the core hands it each picture's data and the M2 unit's settings,
  and it hands back the picture in the M2's pixel format, as the M2's own MPEG unit does. Nothing in it is specific to Battle
  Tryst, so any M2-hardware core can use it. Its source, the module's source and the build scripts are in `hps/m2mpegd/`.

### Tested

On a MiSTerPi (kernel 5.15.1) and a DE10-Nano (6.18.38), both with the SDRAM board: the intro and attract movies looped,
watched for tears and sound, none seen. The DE10-Nano ran the decoder overnight: 27,404 pictures, none late, no errors.

## Controls and OSD

**Tobe! Polystars:** a joystick, Shoot, Bomb, Start and Coin, for two players. The default pad layout: B shoots, A bombs, Start,
Select for a coin.

**Battle Tryst:** a joystick, Guard, Punch, Kick, Start and Coin, for two players. The default pad layout: A guards, B punches,
X kicks, Start, Select for a coin.

**Heat of Eleven '98:** a joystick, Pass/Tackle/Lifting, Long/Sliding/H.Lift and Shift (named as in the game's guides), Start and
Coin, for two players. The default pad layout: A, B and X are the three buttons in that order, Start, Select for a coin.

**Evil Night, Hell Night and Total Vice:** a light gun for each player (three in Evil Night and Hell Night, two in Total Vice), with
Trigger, Reload, Start and Coin. The default pad layout: B is the trigger, A reloads, Start, Select for a coin. Each player's
**Input** in the OSD is what that player aims with, and the OSD shows only the settings of the Inputs in use:

- **Controller** (the default): the pad's left stick and d-pad, with a crosshair. Controller stick: Position (the aim goes where
  the stick points and back to the middle when it's let go; a full push keeps it moving, out to the edges) or Move (the stick
  moves the aim while it's pushed, as the d-pad does).
- **Mouse**: its movement aims, its left button is the trigger and its right reloads, with a crosshair.
- **Sinden**: a Sinden gun, with the white border it needs round the picture (Sinden border, below) and no crosshair.
- **Light gun**: any other gun that MiSTer sees as a pad's left analog stick (GUN4IR and the like), with no border and no crosshair.

Crosshair (On, Off) is for the players on Controller or Mouse; a player's crosshair shows once that player has aimed or fired,
so an idle player's isn't in the way. Off-screen edge is for the guns: how near the left or right edge, or the top, a gun counts as
off the screen. MiSTer gives a Sinden's trigger and reload as the mouse's buttons, and joins every mouse's and gun's buttons into
one, so the mouse's buttons go to the first player on Mouse, Sinden or Light gun: two Sindens' triggers can't be told apart.

**A Sinden gun** finds the screen by a white border round the picture, which the core draws while a player's Input is Sinden
(Sinden border, 16 px by default). The sides and the bottom are that wide, the top stays thin so the scores there stay readable,
and a black band inside the white keeps the game's own bright pixels from touching it. 16 px or more holds the aim steady on Total
Vice's dark screens; at 8 px the gun can take a bright edge in the room for the picture's side.

Reloading: in Evil Night and Hell Night, Players 1 and 3 aim up (their guns have a mercury switch) and Player 2 presses a button; in Total Vice,
each player shoots off the screen. Reload (Button 2) does each of these for you.

The service coin isn't on a button: Coin does the same.

**Pause and Step** (every game; R and L on the pad): Player 1's Pause holds the machine and the sound, with the picture as it is, and
Pause again goes on (a reset ends it too). While paused, Step runs one frame and holds again: for screenshots.

| Option | Values |
|---|---|
| CD audio image | the disc's whole image, `<set>_full.bin` |
| Aspect ratio | Original, Full Screen, two custom |
| Scale | Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+ |
| CRT Adjust (page) | Off, On; H-Size 0 to +5 and -16 to -1, H-Position -48 to +16, V-Shift -16 to +15: rmonic79's CRT Adjust (`modules/crt-adjust`, `rtl/m2_crt.sv`) for an analog CRT, Hell Night's 24 kHz too: the picture is sized and moved through a line buffer while the sync keeps its timing, so the monitor stays locked. A size step is 1/80 of a pixel (1/64 in Hell Night), about 8 pixels across the picture; a position step is 2 pixels. The position stops where the picture would reach into the hsync pulse or past the line's end, so a line is always whole: in the 640 x 240 games H-Size +2 to +5 stop it further left (at +5 from -2: the picture moves 4 pixels left), and -13 to -16 at -47 and -46; in Hell Night it goes from -23 at H-Size 0 (-14 at -16, -25 at +5) to +16 (+14, +9 and +5 at H-Size +3, +4 and +5). Far left, the picture is in the black before it that a CRT measures: if its brightness changes there, move it back. Off, the picture passes straight through, as before |
| P1 Input, P2 Input, P3 Input (gun games; P3 in Evil Night and Hell Night) | Controller (the default), Mouse, Sinden, Light gun: what the player aims with (above) |
| Controller stick (shown with a player on Controller) | Position, Move |
| Crosshair (shown with a player on Controller or Mouse) | On, Off: each such player's, once that player aims |
| Sinden border (shown with a player on Sinden) | 16 px, 24 px, 8 px: the white border a Sinden gun needs (above) |
| Off-screen edge (shown with a player on Sinden or Light gun) | 4 px, 2 px, 8 px, 10 px: a gun this near the left or right edge, or the top, is off the screen (to reload) |
| Service mode | Off, On: the game's service menu |
| Pause when OSD is open | Off, On |
| Advanced: CPU caches (at reset) | 32 KB, 16 KB, 8 KB, 4 KB as the 602 (each side; Hell Night's build is fixed at 32 KB) |
| Advanced: SDRAM read timing (Battle Tryst, Heat of Eleven, Hell Night) | Normal, Late: the Z buffer's reads a clock later, for a module that answers slowly |
| Advanced: CPU 2 DEC interrupt | Off (the default), On: whether CPU 2 takes its decrementer exception. On is the 602's own behavior, but with it the M2 OS's scheduler can run on CPU 2 and corrupt its task queue (a freeze after hours); DEC counts either way |
| DIP Switches | Polystars and Total Vice: Sound Output (Stereo, Mono), Flip Screen (Off, On). Evil Night and Hell Night: Flip Screen. Battle Tryst and Heat of Eleven: none |

**The service menus:** Evil Night's opens an item with the trigger. Total Vice's opens one only with Player 2's Start; while Service mode is On, Player 1's Button 3 (*Select (Service)*, X on the pad) does the same, so one controller is enough.

The service menu's settings (Free Play, the volume and the rest) are kept in the game's EEPROM, which MiSTer saves to `config/nvram/`
when the OSD is opened, and loads at the next start. The EEPROMs in Evil Night's, Hell Night's and Total Vice's MAME sets hold the
factory sound volume, which is just as quiet in MAME (Evil Night and Hell Night 12 of 30, Total Vice 4 of 31), so their MRAs set it
to 20, 20 and 24. Total Vice's MRA
also sets GAME OPTIONS' VIOLENT MODE to BLOODY: the set has CLEAN, with no blood. A saved EEPROM in `config/nvram/` takes the MRA's place:
delete it to have the MRA's settings again. Evil Night's blood is GAME OPTIONS' BLOOD COLOR, which the set has at LIGHTNING.

**The M48T58** (Battle Tryst, Heat of Eleven, Evil Night, Hell Night): the board's battery-backed RAM and clock. Its 8 KB is saved with
the EEPROM in the same file in `config/nvram/` (128 bytes of EEPROM, then the 8 KB). In MAME, Battle Tryst writes coin counts there on
every coin, and Heat of Eleven's match lighting follows the clock's time of day; both games' service menus show the clock (Battle
Tryst's BOOKKEEPING page, Heat of Eleven's ADJUST SYSTEM CLOCK). The clock is set from the MiSTer's clock (local time) when the
core starts, then runs on its own; a time the game sets holds until the core is loaded again. A 128-byte save from an older build
of these four games still gives the EEPROM its settings; the M48T58 starts from the MRA's image that once, and the next save has both.

## Notes

- **Speed:** in Polystars, where the real board slows down, the core slows down less (above). The other games haven't been timed
  against a real board. Two scenes are known to run slow: Hell Night's continue screen, whose 10 s take about 17, and Battle Tryst's
  character select, at about a third of its speed (its matches are close to full speed).
- **Hell Night** (ver EAA), Evil Night's European version, draws only in High Res, on the arcade monitor (512 x 384, about 24 kHz),
  where on this core the other games draw in Low Res (640 x 240, the TV's): its MRA's board byte asks for that raster, and its guns'
  range is MAME's hellngt's. A CRT for it needs to take 24 kHz. Its frame rate on the core is 58.6 Hz where MAME's is 59.5 Hz, so it
  runs about 1.6 % slow.
- **The SDRAM board's builds** (Hell Night, Battle Tryst, Heat of Eleven) keep the Z buffer there. On the bench, with the Z buffer in
  SDRAM, a few pixels of some pictures take another pixel's colour; not yet fixed.
- **In MAME:** MAME 0.289 marks Battle Tryst and Heat of Eleven '98 as preliminary. Its Heat of Eleven runs the attract mode; its
  Battle Tryst stops at the MPEG intro, which the core gets past. Total Vice's JAD, AAB and UAC sets are marked not working, and
  aren't supported.

## What is verified

- From power-on, in simulation (`sim/m2boot`), the machine loads the OS from the CD image and shows the same boot checks and title
  screen as MAME.
- The Triangle Engine's writes are the same as MAME's, byte for byte, on the lists dumped from the game (`sim/te`).
- The CPUs against MAME's instruction traces (`sim/ppcreplay`) and against a reference model with random programs and interrupts
  (`sim/ppccore`), the caches' coherence (`sim/coh`).
- The YMZ280B against a port of MAME's device on Evil Night's sample ROM, sample for sample, on random voices and on the game's own
  writes (`sim/ymz`). The audio DSP against MAME's interpreter (`sim/dspp`); on MAME's dumps of each game's DSP program, each sample's
  work fits in the 1512 clocks it has (Total Vice's, the longest, takes at most 1319).
- `tools/m2disc.py`'s files, for Polystars, Evil Night and Total Vice, are byte for byte the ones played on the board, and so are
  the browser converter's for Evil Night and Total Vice. For Hell Night, Battle Tryst and Heat of Eleven, MAME 0.289's own CHDs give
  the same data sectors as the Redump-based CHDs they were tested with, and the browser converter's files from them are byte for
  byte `tools/m2disc.py`'s.
- On a real MiSTer, HDMI and a Sony CRT: Polystars' attract mode for 60 minutes; the whole game played through, with the repaired
  disc image without a gap in the music. Evil Night and Total Vice played, with their music and sound effects. Hell Night, Battle
  Tryst and Heat of Eleven '98 played on their own cores, with the SDRAM board.
- By tallendorf, on a MiSTerPi, a MultiSystem 2 and a DE10-Nano with the SDRAM board: Hell Night and Heat of Eleven '98 played, a
  Battle Tryst match played; Hell Night's attract for 10 h without a freeze, and Battle Tryst's for 17.2 h and 16.6 h on a debug build
  that forces CPU 2's decrementer every half second, with the OSD's gate (*CPU 2 DEC interrupt* Off).

The plan and how the machine is built are in [docs/design.md](docs/design.md); what is known of the hardware is in
[docs/hardware.md](docs/hardware.md).

## Repository

| | |
|---|---|
| `KonamiM2.sv` | the MiSTer top level (`emu`) |
| `rtl/` | the machine |
| `sim/` | Verilator benches (CRT Adjust's, `sim/crt`, Icarus Verilog), run from WSL; `sim/run_all.sh` runs them all, one PASS / FAIL line each |
| `tools/` | the disc files' maker (`m2disc.py`, with `cdimage.py` and `cdfix.py`), MAME capture scripts (`tools/lua/`), the reports, the reference models (`tools/ref/`) |
| `mra/`, `releases/`, `dist/` | MRAs, the tested RBFs with their fitter / timing summaries, release notes and zips |
| `hps/m2mpegd/` | the MPEG decoder for Battle Tryst's movies, on the MiSTer's ARM (`m2mpegd`), its scripts and kernel module |
| `modules/` | vendored: rmonic79's CRT Adjust, with the owner's other cores' changes (`modules/VENDOR.md`) |
| `sys/` | the MiSTer framework |

The benches expect the owner's layout: this repository at `/mnt/c/repos/konamim2-mister/mister` and, next to it, `work/` with what is
never committed: MAME's sources (`work/mame/`), the romsets (`work/roms/`) and captures (`work/cap/`). A bench whose capture is missing is
skipped.

## Building

Quartus Prime Lite 17.0: open `KonamiM2.qpf` and compile; the RBF is `output_files/KonamiM2.rbf`.

Or from the command line, with `quartus_sh` on the PATH: `python3 tools/build.py [default|hellngt|tryst|heat]` compiles the
default build, Hell Night's, Battle Tryst's or Heat of Eleven's (the qsf's lines for it, its seed) in a copy under `build/`, and puts
the RBF in `releases/` as `KonamiM2_<date>.rbf`, `KonamiM2HellNight_<date>.rbf`, `KonamiM2Tryst_<date>.rbf` or
`KonamiM2Heat_<date>.rbf` (the names the MRAs ask for),
with its fitter and timing summaries, if it meets timing on every clock. `tools/package.py` puts the games' builds of the
release's date in its zip, with their MRAs.

## Capturing from MAME

`tools/lua/m2_capture.lua` records what Polystars asks of the triangle engine and the rest of the BDA: lists, triangles and
their render states, texture loads, the units' traffic, and (with `-debug`) per-frame CPU traces. Its settings are at the top
of the script; `tools/m2_report.py` summarises a capture.

```
mame polystar -window -nothrottle -autoboot_script tools/lua/m2_capture.lua
python3 tools/m2_report.py m2cap
```

`tools/lua/ppc_trace.lua` traces one CPU instruction by instruction (registers before each, every data access) from power-on
or from a given frame, for `sim/ppcreplay`; how to run it is at the top of the script.

## Credits

* **MAME**: the konamim2 driver and the 3DO M2 devices (`3dom2.cpp`, `3dom2_te.cpp`; Phil Bennett), the PowerPC core (Aaron Giles,
  R. Belmont; `tools/ref/`'s reference model follows it), the CD drive, the YMZ280B (`ymz280b.cpp`; Aaron Giles); the hardware
  knowledge and the reference for every comparison.
* The owner's Slap Shot core: the light guns (`rtl/m2_guns.sv`, after the owner's Seta 2 core and ppriest's `gx_guns.sv`).
* tallendorf: the single-precision float units and the FP-unavailable exception, triangle engine and DSP fixes and speed-ups,
  Hell Night's, Battle Tryst's and Heat of Eleven's builds (the Z buffer in the SDRAM, based on the owner's Gaelco 3D core; the
  arcade monitor's raster; the CD streaming; the MPEG unit's control and its decoder on the ARM; compressed texture loads), the fix for CPU 2's decrementer
  freeze, the CPU cache size option, `tools/build.py`, `tools/cdimage.py`'s older CHDs.
* The owner's Gaelco 3D core: the platform layer, the base of the Z buffer in the SDRAM (`rtl/m2_zmem.sv`), the way each block is
  checked, the benches and the release packaging.
* **rmonic79 (Umberto Parisi)**, with Andrea Bogazzi (asturur): CRT Adjust (GPL-3.0-or-later).
* The MiSTer framework (Sorgelig and contributors).

## Licence

GPL-3.0-or-later (`LICENSE`). The vendored modules keep their own licences (`modules/VENDOR.md`).
