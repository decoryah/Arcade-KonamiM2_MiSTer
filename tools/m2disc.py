#!/usr/bin/env python3
"""Make a game's disc files for the core from its MAME CHD, in one step (Python 3 and MAME's chdman, nothing else):

  python3 tools/m2disc.py <game.chd> [chdman]

chdman is MAME's tool (chdman.exe on Windows), from the PATH unless given. Into the current directory it writes, for the game's set:

  <set>_cd.zip      the data track as the core's CD drive reads it (tools/cdimage.py): games/mame/, beside <set>.zip
  <set>_full.bin    the whole disc, 2352 bytes a sector, for the music: games/<set>/
  <set>_full.cue    its cue sheet (the core doesn't need it)

The discs: polystar/623jaa02.chd (Tobe! Polystars), evilngt/810uba02.chd (Evil Night), totlvice/639eba01.chd (Total Vice). A CHD that
keeps its data track as 2048-byte sectors (Total Vice's, older Polystars ones) has it padded to 2352, as the core finds a sector of the
music at its LBA x 2352 in the image. Polystars' music is also repaired (tools/cdfix.py).
"""
import hashlib
import os
import re
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cdfix     # noqa: E402
import cdimage   # noqa: E402

# (tracks, the data track's sectors): the set. Total Vice's other versions (AAB, JAD, UAC) have the same layout, so the data image's
# SHA-256 tells the disc the MRA wants from them
DISCS = {
    (25, 11928): 'polystar',
    (27, 28310): 'evilngt',
    (21, 20632): 'totlvice',
}
DATA_SHA256 = {
    'polystar': ('623jaa02.chd', '6a88f76a9c1e3409398180b6997a406fa4bb72a6c60c24603fe1faa7ab4133c3'),
    'evilngt': ('810uba02.chd', '80c5f795eaba463117c4f21f853bc1c828e936a7fc8f23f9a544457ab2dedd63'),
    'totlvice': ('639eba01.chd', '9a18db4003dc6e1963c724da2f1480e35c6cc5c28c23be0da9f6ec3528a11a7d'),
}


def main(chd, chdman='chdman'):
    tr = cdimage.toc(chdman, chd)
    key = (len(tr), tr[0][2])
    if key not in DISCS:
        sys.exit(f'{chd}: {key[0]} tracks, a data track of {key[1]} sectors: not 623jaa02, 810uba02 or 639eba01')
    name = DISCS[key]
    cooked = tr[0][1] == 'MODE1'
    print(f'{chd}: {name}, data track {tr[0][1]}' + (' (2048-byte sectors, padded to 2352)' if cooked else ''))
    with tempfile.TemporaryDirectory(dir='.') as d:
        cue, b = cdimage.extract(chdman, chd, d)

        cd = os.path.join(d, name + '_cd.bin')
        cdimage.write(tr, b, cd)
        with open(cd, 'rb') as f:
            h = hashlib.sha256(f.read()).hexdigest()
        want, sha = DATA_SHA256[name]
        if h != sha:
            sys.exit(f'{chd}: has the layout of {want}, but not its data: another version of the disc (Total Vice: AAB, JAD or UAC?).'
                     f' The core runs only {want}.')
        with zipfile.ZipFile(name + '_cd.zip', 'w', zipfile.ZIP_DEFLATED) as z:
            z.write(cd, name + '_cd.bin')
        print(name + '_cd.zip')

        full = name + '_full.bin'
        if cooked:
            with open(b, 'rb') as f, open(full + '.tmp', 'wb') as o:
                for _ in range(tr[0][2]):
                    s = f.read(2048)
                    if len(s) != 2048:
                        sys.exit(f'{chd}: the extracted disc ends inside its data track')
                    o.write(s + bytes(304))
                while True:
                    s = f.read(1 << 20)
                    if not s:
                        break
                    o.write(s)
            os.replace(full + '.tmp', full)
        else:
            os.replace(b, full)
        with open(cue) as f:
            text = f.read()
        with open(name + '_full.cue', 'w') as f:
            f.write(re.sub(r'FILE "[^"]*"', 'FILE "' + full + '"', text).replace('MODE1/2048', 'MODE1/2352'))
        print(full, os.path.getsize(full), 'bytes, and', name + '_full.cue')

    if name == 'polystar':
        cdfix.main(full, full)


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    main(*sys.argv[1:])
