## Konami M2 for MiSTer - 20261112

Konami's **M2** arcade board (1997-1998), the 3DO M2 hardware: two PowerPC 602s at 66.67 MHz, a triangle engine, an audio DSP and a CD
drive. Three MRAs: **Tobe! Polystars** (ver JAA, 1997), Konami's 3D shooter, and the light-gun games **Evil Night** (ver UBA, 1998) and
**Total Vice** (ver EBA, 1997).

**Two new games, with light guns.** Tested on a real MiSTer by the repository owner: Evil Night and Total Vice played, with their music
and sound effects.

### What's new

- **Evil Night and Total Vice:** Konami's light-gun games on the M2, for up to three players in Evil Night and two in Total Vice. New in
  the core for them: the YMZ280B sample chip of their boards (sample for sample a port of MAME's, on Evil Night's own writes), the guns,
  their boards' 16 MB of RAM and room for their larger discs (up to 64 MB of data track).
- **Light guns:** aim with a light gun that MiSTer sees as a pad's analog stick (Sinden, GUN4IR), a pad's stick or d-pad, or a mouse;
  Trigger and Reload; a crosshair for each player if you want one. Reload (Button 2) does what each game wants: in Evil Night, Players
  1 and 3 aim up and Player 2 presses a button; in Total Vice, each player shoots off the screen.
- **Sound effects without clicks:** the audio DSP takes fewer clocks per instruction. Total Vice's effects program needed more time
  than a sample has, which gave clicks; it now takes at most 1319 of the 1512 clocks. The sound is also output on the 44.1 kHz tick.
- **Volume and blood:** the EEPROMs in Evil Night's and Total Vice's MAME sets hold the factory sound volume, which is just as quiet in
  MAME. The MRAs set Evil Night's SOUND VOLUME to 20 of 30 (12 in the set) and Total Vice's VOLUME and GUN VOLUME to 24 of 31 (4 in the
  set), and Total Vice's VIOLENT MODE to BLOODY (CLEAN in the set). Both can be changed in the games' service menus.
- **Total Vice's service menu** opens an item only with Player 2's Start: while Service mode is On, Player 1's Button 3 (*Select
  (Service)*, X on the pad) does the same, so one controller is enough.
- **Picture:** 240p's vertical sync is where CEA-861 has it, so the last lines show on scalers that cut them off before (Total Vice's
  INSERT COINS).
- **OSD:** CD audio image first, then Aspect ratio and Scale, then the guns' options, Service mode and the DIP switches.
- **Disc files:** the new `tools/m2disc.py` makes a game's files from its CHD in one step, for all three games (below), and so does
  the browser converter now.

### Install

1. Unzip `KonamiM2_MiSTer_20261112.zip` over the root of the SD card. It adds `_Arcade/cores/KonamiM2_20261112.rbf` and three MRAs to
   `_Arcade/`: `Tobe! Polystars (ver JAA).mra` (only a comment differs from 20261110's), `Evil Night (ver UBA).mra` and
   `Total Vice (ver EBA).mra`.
2. Make each game's disc files from the CHD in your own MAME 0.289 set. No ROMs or disc images are included. If you have Polystars'
   from 20261110, keep them.

   | Game | The CHD | Makes |
   |---|---|---|
   | Tobe! Polystars | `polystar/623jaa02.chd` | `polystar_cd.zip`, `polystar_full.bin` (546 MB), `polystar_full.cue` |
   | Evil Night | `evilngt/810uba02.chd` | `evilngt_cd.zip`, `evilngt_full.bin` (515 MB), `evilngt_full.cue` |
   | Total Vice | `totlvice/639eba01.chd` | `totlvice_cd.zip`, `totlvice_full.bin` (522 MB), `totlvice_full.cue` |

   - **Any of the three, with the repository's `tools/m2disc.py`** (Python 3 and MAME's `chdman`, nothing else), from the folder you
     want the files in:

     ```
     python3 tools/m2disc.py polystar/623jaa02.chd
     python3 tools/m2disc.py evilngt/810uba02.chd
     python3 tools/m2disc.py totlvice/639eba01.chd
     ```

     If `chdman` isn't on the PATH, give it after the CHD; on Windows, for example,
     `py tools\m2disc.py totlvice\639eba01.chd C:\mame\chdman.exe`. It repairs Polystars' music (the 28 gaps of MAME's bad dump), and
     pads Total Vice's data track, which its CHD keeps as 2048-byte sectors, so that the core finds the music. It turns down Total
     Vice's other versions (AAB, JAD, UAC), which the core doesn't run.
   - **Any of the three, in a browser:** the [Konami M2 CHD converter](https://konami-m2-chd-converter.fueledmyrrh2.chatgpt.site/); for
     Polystars, with *Repair gaps in Polystars music* ticked. The conversion runs on your computer, and the CHD isn't uploaded.
3. For each game, put your `<set>.zip` and `<set>_cd.zip` in `games/mame/`, and `<set>_full.bin` and `<set>_full.cue` in
   `games/<set>/` (`<set>` is `polystar`, `evilngt` or `totlvice`).
4. Start the game from the Arcade menu. Once for each game, open the OSD and choose its `<set>_full.bin` under *CD audio image*; Main
   remembers it for that game and mounts it at each start. The MRA also asks for it, but Main releases up to 20261010 don't act on
   that. Without it the game runs without its music.

The OSD's version line reads `v261111`, the day the core was built.

### Video

- **The signal:** 640 x 240 shown on a raster of 857 x 262, 15.56 kHz, 59.39 Hz, near MAME's 768 x 262 at 59.36 Hz, with a TV's
  blanking and CEA-861's vertical sync. For a CRT as well as HDMI.
- **Aspect ratio:** Original, Full Screen and the two custom ratios.
- **Scale:** Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+.

### Controls

- **Tobe! Polystars:** a joystick, **Shoot** and **Bomb**, Start and Coin, for two players. The default pad layout: B shoots, A bombs,
  Start, Select for a coin.
- **Evil Night and Total Vice:** a gun for each player, with **Trigger** and **Reload**, Start and Coin. The default pad layout: B is
  the trigger, A reloads, Start, Select for a coin; in Total Vice, X is *Select (Service)*.

### OSD

CD audio image, Aspect ratio, Scale; for the gun games each player's stick (Auto, Aim, D-pad), the mouse's player and the crosshairs;
Service mode, DIP Switches (Sound Output and Flip Screen, Evil Night only Flip Screen), Reset.

### Checked

- **On a real MiSTer:** by the repository owner: Evil Night and Total Vice played, the guns' trigger and reload, their music and sound
  effects, on builds of this design (the last differed only in Button 3 and a sound test option). Tobe! Polystars as in 20261110:
  the whole game played through, the speed timed on stage 3 against a video of the real board.
- **Against MAME 0.289, in simulation** (Verilator): the YMZ280B sample for sample against a port of MAME's on Evil Night's own writes;
  the DSP against MAME's interpreter, and on MAME's dumps of each game's DSP program, the clocks it takes; Evil Night's and Total Vice's
  boot to the attract mode, and Polystars' still. The CPUs and the triangle engine as in 20261110.
- **The disc files:** `tools/m2disc.py`'s, for all three games, are byte for byte the ones played on the board, and so are the
  browser converter's for Evil Night and Total Vice.
- **Quartus 17.0.2:** seed 4 (seeds 5 and 2 miss HDMI's timing): 37,938 ALMs (91 %), 538 of 553 M10K blocks, 64 of 112 DSPs. Timing
  is met on every clock: +1.071 ns on the machine's, +0.566 ns on HDMI's.

### Known differences / open points

- Evil Night's and Total Vice's speed hasn't been timed against a real board. In Polystars, where the real board slows down, the core
  slows down less.
- **Games:** Hell Night (ver EAA), Evil Night's other version, is planned: its picture and its guns' range differ. Total Vice's JAD,
  AAB and UAC sets, Battle Tryst and Heat of Eleven '98 are marked not working in MAME 0.289, so the core can't be checked against it
  for them.
- **MPEG:** the 3DO M2's MPEG video decoder isn't in the core. No Konami M2 game is known to need it: MAME has only an empty stand-in
  for it and runs all three games without one.
- No CRT Adjust and no Scandoubler Fx yet. The volume is each game's own, in its service menu.

### Credits

MAME (the konamim2 driver and the 3DO M2 devices by Phil Bennett, the PowerPC core by Aaron Giles and R. Belmont, the YMZ280B by Aaron
Giles), tallendorf (the single-precision float units, the FP-unavailable exception, the triangle engine and DSP fixes, Heat of Eleven's
build, `tools/cdimage.py`'s older CHDs), the repository owner's Slap Shot core (the light guns), the repository owner's Gaelco 3D core
(the platform layer, the benches, the packaging), and the MiSTer framework.
