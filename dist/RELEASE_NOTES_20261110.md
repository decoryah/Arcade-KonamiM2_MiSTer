## Konami M2 for MiSTer - 20261110

Konami's **M2** arcade board (1997-1998), the 3DO M2 hardware: two PowerPC 602s at 66.67 MHz, a triangle engine, an audio DSP and a CD
drive. One MRA: **Tobe! Polystars** (ver JAA, 1997), Konami's 3D shooter.

**Full speed, and no gaps in the music.** Tested on a real MiSTer by the repository owner: the whole game played through.

### What's new

- **Speed:** the CPUs are faster: data caches of two 16 KB ways, a load or store each clock, float results passed on as they leave
  the pipeline, a faster divide and square root, and tallendorf's single-precision float units, as the 602 has. Stage 3, timed against
  a video of the real board, takes 154.8 s where the board takes 173.6 s: 112 % of its speed (110 % before the lava, 133 % in it,
  106 % after). Where the real board slows down, the core slows down less. 20261106 ran at about 83 % of the real board's speed.
- **Music:** short gaps in the music, most of them in the stage 7 boss fight. They're in the disc image: MAME marks `623jaa02.chd` as a
  bad dump, and its music has 28 stretches of 0.35 s of silence, where the ripper's reads failed. The new `tools/cdfix.py` fills each
  from the same music elsewhere in its track, as the music repeats (Install, step 3). With the repaired image, a whole game played
  without a gap.
- **From tallendorf's pull requests:** textures drawn smaller than their size use the minify filter; literal texels and texture loads
  from any byte address fixed; the blender as in the BDA spec's reference model; the DSP takes fewer clocks per instruction; the CPUs'
  FP-unavailable exception, so tasks don't share the float registers. Also a build for Heat of Eleven '98 with its own MRA, which isn't
  in this release.
- **Room:** the core uses 87 % of the chip, down from 99 %, thanks to the single-precision float units.

### Install

1. Unzip `KonamiM2_MiSTer_20261110.zip` over the root of the SD card. It adds `Tobe! Polystars (ver JAA).mra` to `_Arcade/` (the same as
   20261106's) and `_Arcade/cores/KonamiM2_20261110.rbf`.
2. If you have the disc's images from 20261106, keep them and go on to step 3. If not, make them from your own MAME 0.289 set's
   `623jaa02.chd` (`polystar/623jaa02.chd`), in either of these ways. No ROMs or disc images are included.

   - **In a browser:** choose the CHD in the [Konami M2 CHD converter](https://konami-m2-chd-converter.fueledmyrrh2.chatgpt.site/) and download the
     three files it makes: `polystar_cd.zip`, `polystar_full.bin` and `polystar_full.cue`. The conversion runs on your computer, and the CHD isn't
     uploaded. It needs a desktop browser (Chrome or Edge) and about 2 GB of free memory, and takes only this disc.
   - **By hand:** with MAME's `chdman` and the repository's `tools/cdimage.py`:

     ```
     chdman extractcd -i polystar/623jaa02.chd -o polystar_full.cue -ob polystar_full.bin
     python3 tools/cdimage.py chdman polystar/623jaa02.chd polystar_cd.bin
     zip polystar_cd.zip polystar_cd.bin
     ```

     The first makes the whole disc, for the music (`polystar_full.bin`, 546 MB, with its `.cue`); the second its data track (`polystar_cd.bin`, 24 MB).
3. Repair the music with the repository's `tools/cdfix.py` (Python 3, nothing else needed):

   ```
   python3 tools/cdfix.py polystar_full.bin
   ```

   It repairs the file in place, after checking it: a file that isn't this image, or is already repaired, is left alone. It holds
   only positions; all the audio comes from your image.
4. Put your `polystar.zip` and `polystar_cd.zip` in `games/mame/`, and `polystar_full.bin` and `polystar_full.cue` in `games/polystar/`.
5. Start the game from the Arcade menu. Once, open the OSD and choose `polystar_full.bin` under *CD audio image*; Main remembers it and
   mounts it at each start. The MRA also asks for it, but Main releases up to 20261010 don't act on that. Without it the game runs
   without its music.

The OSD's version line reads `v261109`, the day the core was built.

### Video

- **The signal:** 640 x 240 shown on a raster of 857 x 262, 15.56 kHz, 59.39 Hz, near MAME's 768 x 262 at 59.36 Hz, with a TV's blanking.
  For a CRT as well as HDMI.
- **Aspect ratio:** Original, Full Screen and the two custom ratios.
- **Scale:** Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+.

### Controls

A joystick, **Shoot** and **Bomb**, Start and Coin, for two players. The default pad layout: B shoots, A bombs, Start, Select for a coin.

### OSD

Aspect ratio, Scale, CD audio image, Service mode, DIP Switches (Sound Output, Flip Screen), Reset.

### Checked

- **On a real MiSTer:** by the repository owner: the whole game played through on this build, more than once; with the repaired disc
  image, a whole game without a gap in the music. The speed timed on stage 3 against a video of the real board.
- **Against MAME 0.289, in simulation** (Verilator): the boot from the CD image to the title screen, the CPUs against MAME's instruction
  traces, and the triangle engine's writes byte for byte MAME's on the lists dumped from the game. The CPUs also against a reference
  model on random programs, with random memory delays and interrupts, and the caches' coherence.
- **Quartus 17.0.2:** seed 2 (all four seeds tried meet timing): 36,562 ALMs (87 %), 539 of 553 M10K blocks, 60 of 112 DSPs. Timing is
  met on every clock: +1.592 ns on the machine's, +0.221 ns on HDMI's.

### Known differences / open points

- Where the real board slows down, the core slows down less: in stage 3's lava, it runs a third faster than the board.
- MAME only estimates the triangle engine's timing, so the speed is compared with the real board, not MAME.
- **Games:** this core plays Tobe! Polystars, the only MRA. The other Konami M2 games aren't supported yet:
  - Total Vice (ver EBA) and Evil Night / Hell Night are planned. They work in MAME 0.289, haven't been run on this core yet, and may
    need more of the board, such as Evil Night's light guns.
  - Total Vice's JAD, AAB and UAC sets, Battle Tryst and Heat of Eleven '98 are marked not working in MAME 0.289, so the core can't be
    checked against it for them.
- **MPEG:** the 3DO M2's MPEG video decoder isn't in the core. No Konami M2 game is known to need it: MAME has only an empty stand-in
  for it and runs Polystars, Total Vice and Evil Night without one.
- No CRT Adjust, no Scandoubler Fx and no volume yet.

### Credits

MAME (the konamim2 driver and the 3DO M2 devices by Phil Bennett, the PowerPC core by Aaron Giles and R. Belmont), tallendorf (the
single-precision float units, the FP-unavailable exception, the triangle engine and DSP fixes, Heat of Eleven's build,
`tools/cdimage.py`'s older CHDs), the repository owner's Gaelco 3D core (the platform layer, the benches, the packaging), and the MiSTer
framework.
