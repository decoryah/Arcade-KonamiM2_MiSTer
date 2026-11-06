## Konami M2 for MiSTer - 20261106

Konami's **M2** arcade board (1997-1998), the 3DO M2 hardware: two PowerPC 602s at 66.67 MHz, a triangle engine, an audio DSP and a CD
drive. One MRA: **Tobe! Polystars** (ver JAA, 1997), Konami's 3D shooter.

**Faster, with the sound fixed, the service settings saved and the board's DIP switches in the OSD.** Tested on a real MiSTer by the
repository owner.

### What's new

- **Speed:** the triangle engine draws faster. The attract mode's gameplay demo, from STAGE 1 START to the first OPTION x2, takes
  102.9 s, where a video of the real board takes 85.0 s: about 83 % of the real board's speed in gameplay. The title and intro scenes
  run at the real board's pace.
- **Sound:** sound effects, and later the music, could drop out after a while and stay gone. Fixed.
- **Picture:** the ground could be drawn over the houses in places, and a few pixels were missing at the picture's lower left. Fixed.
- **Service settings are saved:** what's set in the service menu (Free Play, difficulty and the rest) is kept on the SD card, in
  `config/nvram/`, and loaded at the next start. MiSTer saves it when the OSD is opened.
- **DIP switches:** the board's two, *Sound Output* (Stereo by default) and *Flip Screen*, under DIP Switches in the OSD.
- **Controls:** the buttons have the game's names, *Shoot* and *Bomb*, with a default pad layout. The Service button is gone: Coin does
  the same, and the OSD's Service mode opens the service menu.
- **`tools/cdimage.py`:** a CHD whose data track is stored at 2048 bytes a sector (an older dump) now works. From tallendorf's pull request.

### Install

1. Unzip `KonamiM2_MiSTer_20261106.zip` over the root of the SD card. It adds `Tobe! Polystars (ver JAA).mra` to `_Arcade/` and
   `_Arcade/cores/KonamiM2_20261106.rbf`. Use this release's MRA: the settings save, the DIP switches and the button names are in it.
2. Make the disc's images from your own MAME 0.289 set's `623jaa02.chd` (`polystar/623jaa02.chd`), in either of these ways. No ROMs or disc
   images are included.

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
3. Put your `polystar.zip` and `polystar_cd.zip` in `games/mame/`, and `polystar_full.bin` and `polystar_full.cue` in `games/polystar/`.
4. Start the game from the Arcade menu. Once, open the OSD and choose `polystar_full.bin` under *CD audio image*; Main remembers it and
   mounts it at each start. The MRA also asks for it, but Main releases up to 20261010 don't act on that. Without it the game runs
   without its music.

The OSD's version line reads `v261106`.

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

- **On a real MiSTer:** by the repository owner: the attract mode looped for 90 minutes and games were played, with music and sound
  effects throughout, on a test build without the settings save and the DIP switches. On this build: saving the service settings, the DIP switches and the new controls checked, the attract mode and a game played.
- **Against MAME 0.289, in simulation** (Verilator): the boot from the CD image to the title screen, the CPUs against MAME's instruction
  traces, and the triangle engine's writes byte for byte MAME's on the lists dumped from the game.
- **Quartus 17.0.2:** the best of four seeds (seed 4): 41,451 ALMs (99 %), 441 of 553 M10K blocks, 69 of 112 DSPs. Timing is 0.362 ns short on the machine's clock, and met on the
  HDMI clock.

### Known differences / open points

- About 83 % of the real board's speed in gameplay, as above. This is the next job.
- MAME only estimates the triangle engine's timing, so the speed is compared with the real board, not MAME.
- **Games:** this core plays Tobe! Polystars, the only MRA. The other Konami M2 games aren't supported yet:
  - Total Vice (ver EBA) and Evil Night / Hell Night are planned. They work in MAME 0.289, haven't been run on this core yet, and may
    need more of the board, such as Evil Night's light guns.
  - Total Vice's JAD, AAB and UAC sets, Battle Tryst and Heat of Eleven '98 are marked not working in MAME 0.289, so the core can't be
    checked against it for them.
- **MPEG:** the 3DO M2's MPEG video decoder isn't in the core. No Konami M2 game is known to need it: MAME has only an empty stand-in
  for it and runs Polystars, Total Vice and Evil Night without one.
- No CRT Adjust, no Scandoubler Fx and no volume: the chip has no room for them now.
- Flip Screen isn't checked against the real board.

### Credits

MAME (the konamim2 driver and the 3DO M2 devices by Phil Bennett, the PowerPC core by Aaron Giles and R. Belmont), tallendorf
(`tools/cdimage.py`), the repository owner's Gaelco 3D core (the platform layer, the benches, the packaging), and the MiSTer framework.
