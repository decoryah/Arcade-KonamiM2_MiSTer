## Konami M2 for MiSTer - 20261105

Konami's **M2** arcade board (1997-1998), the 3DO M2 hardware: two PowerPC 602s at 66.67 MHz, a triangle engine, an audio DSP and a CD
drive. One MRA: **Tobe! Polystars** (ver JAA, 1997), Konami's 3D shooter.

**First release. Tested on a real MiSTer by the repository owner, on HDMI and a Sony CRT: it plays, with its music and sound effects,
but heavy scenes run below the real board's speed.** It was also checked in simulation against MAME 0.289 (below).

### Install

1. Unzip `KonamiM2_MiSTer_20261105.zip` over the root of the SD card. It adds `Tobe! Polystars (ver JAA).mra` to `_Arcade/` and
   `_Arcade/cores/KonamiM2_20261105.rbf`.
2. Make the disc's images from your own MAME 0.289 set's `623jaa02.chd` (`polystar/623jaa02.chd`), with MAME's `chdman` and the
   repository's `tools/cdimage.py`. No ROMs or disc images are included.

   ```
   chdman extractcd -i polystar/623jaa02.chd -o polystar_full.cue -ob polystar_full.bin
   python3 tools/cdimage.py chdman polystar/623jaa02.chd polystar_cd.bin
   zip polystar_cd.zip polystar_cd.bin
   ```

   The first makes the whole disc, for the music (`polystar_full.bin`, 546 MB, with its `.cue`); the second its data track (`polystar_cd.bin`, 24 MB).
3. Put your `polystar.zip` and `polystar_cd.zip` in `games/mame/`, and `polystar_full.bin` and `polystar_full.cue` in `games/polystar/`.
4. Start the game from the Arcade menu. Once, open the OSD and choose `polystar_full.bin` under *CD audio image*; Main remembers it and
   mounts it at each start. The MRA also asks for it, but Main releases up to 20261010 don't act on that. Without it the game runs
   without its music.

With a recent Main_MiSTer the ROM and the data track are copied to the DDR3 in one go (the MRA's `address=` attribute); with an older
one they are streamed, with the same RBF and MRA.

The OSD's version line reads `v261105`.

### Speed

Heavy scenes run below the real board's speed, and the game itself slows with them, as game time follows the pictures. Measured at the
start of stage 1: about 30 pictures a second, where the real board gives about 44.6.

### Video

- **The signal:** 640 x 240 shown on a raster of 857 x 262, 15.56 kHz, 59.39 Hz, near MAME's 768 x 262 at 59.36 Hz, with a TV's blanking.
  For a CRT as well as HDMI.
- **Aspect ratio:** Original, Full Screen and the two custom ratios.
- **Scale:** Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+.

### Controls

A joystick and three buttons, **Button 1**, **Button 2** and **Button 3** (generic names for now), Start, Coin and Service, for two
players, set up in MiSTer's button mapping.

### OSD

Aspect ratio, Scale, CD audio image, Service mode, Reset.

### Checked

- **On a real MiSTer:** by the repository owner: the attract mode looped for 60 minutes without a freeze, then a game with its music and
  sound effects, fades and song changes included. The picture on HDMI and on a Sony CRT.
- **Against MAME 0.289, in simulation** (Verilator):
  - from power-on the machine loads the OS from the CD image and shows the same boot checks and title screen;
  - the CPUs against MAME's instruction traces, the caches' coherence on their own bench;
  - the Triangle Engine's writes are byte for byte MAME's on the lists dumped from the game.
- **Quartus 17.0.2:** the best of four seeds (seed 7): 41,273 ALMs (98 %), 461 of 553 M10K blocks, 69 of 112 DSPs. Timing is 0.264 ns short
  on the machine's clock, and met on the HDMI clock (+0.034 ns). The runs above were on this build.

### Known differences / open points

- Below the real board's speed in heavy scenes, as above. This is the next job.
- MAME only estimates the triangle engine's timing, so the speed is compared with the real board, not MAME.
- Only Tobe! Polystars has been run. Total Vice, Evil Night / Hell Night, Battle Tryst and Heat of Eleven '98 are the same board, not tried.
- The board's MPEG hardware isn't in the core.
- No CRT Adjust, no Scandoubler Fx and no volume: the chip has no room for them now.
- Not checked: stages beyond those played, and a whole game to its end.

### Credits

MAME (the konamim2 driver and the 3DO M2 devices by Phil Bennett, the PowerPC core by Aaron Giles and R. Belmont), the repository
owner's Gaelco 3D core (the platform layer, the benches, the packaging), and the MiSTer framework.
