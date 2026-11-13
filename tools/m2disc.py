#!/usr/bin/env python3
"""Make a game's disc files for the core from its MAME CHD, in one step (Python 3 and MAME's chdman, nothing else):

  python3 tools/m2disc.py <game.chd> [chdman]

chdman is MAME's tool (chdman.exe on Windows), from the PATH unless given. Into the current directory it writes, for the game's set:

  <set>_cd.zip      the data track as the core's CD drive reads it (tools/cdimage.py): games/mame/, beside <set>.zip
  <set>_full.bin    the whole disc, 2352 bytes a sector, for the music: games/<set>/
  <set>_full.cue    its cue sheet (the core doesn't need it)

The discs: polystar/623jaa02.chd (Tobe! Polystars), evilngt/810uba02.chd (Evil Night), hellngt/810eaa02.chd (Hell Night),
totlvice/639eba01.chd (Total Vice), heatof11/703eaa02.chd (Heat of Eleven '98) and btltryst/636jac02.chd (Battle Tryst). A CHD that keeps its data track as 2048-byte
sectors (Total Vice's, older Polystars ones) has it padded to 2352, as the core finds a sector of the music at its LBA x 2352 in the
image, less the 2 s (150 sectors) between the data track and the music, which the image hasn't. Polystars' music is also repaired
(tools/cdfix.py).

Battle Tryst streams its data sectors from <set>_full.bin as it plays (its data track is 367 MB), so its _cd.zip is only the
2048 bytes before the sectors (tools/cdimage.py --header), and its _full.bin has each data sector's 2048 bytes at 16 in, as a raw
sector's. Some CHDs of Heat of Eleven and Battle Tryst going round aren't MAME's: one keeps the 2 s before the music in the
track (it's left out), others haven't any (it's put back, as on the disc, in the table of contents too); their data sectors are
the same, which is what's checked for those two games. Evil Night's and Hell Night's discs have the same layout: their data
tells them apart (Hell Night's is checked on its data sectors, as the CHD we have of it isn't MAME's: it keeps each audio track's
2 s before it).
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

# (tracks, the data track's sectors): the set, or the sets with that layout. Total Vice's other versions (AAB, JAD, UAC) have the
# same layout, so the data image's SHA-256 tells the disc the MRA wants from them; Evil Night and Hell Night share theirs too
DISCS = {
    (25, 11928): 'polystar',
    (27, 28310): ('evilngt', 'hellngt'),
    (21, 20632): 'totlvice',
    (27, 12438): 'heatof11',
    (2, 179352): 'btltryst',
}
DATA_SHA256 = {
    'polystar': ('623jaa02.chd', '6a88f76a9c1e3409398180b6997a406fa4bb72a6c60c24603fe1faa7ab4133c3'),
    'evilngt': ('810uba02.chd', '80c5f795eaba463117c4f21f853bc1c828e936a7fc8f23f9a544457ab2dedd63'),
    'totlvice': ('639eba01.chd', '9a18db4003dc6e1963c724da2f1480e35c6cc5c28c23be0da9f6ec3528a11a7d'),
}
# the games checked on their data sectors alone (the 2048 bytes of each, not the image's first 2048 with the table of contents)
SECTORS_SHA256 = {
    'heatof11': ('703eaa02.chd', 'cda3705c98b069628acc66c8948c88e7ecc8981d06597c1088066f562b689ade'),
    'btltryst': ('636jac02.chd', '8560f7e467b9a98cc558fbba8a973f72ae00b5f8db205be0b9cab8b7a6a887ac'),
    'hellngt': ('810eaa02.chd', '22c3557bb7a5d468399e75fca377b70e47b61ead465ce56d1b3f424d286b9e3e'),
}
STREAMED = {'btltryst'}   # its data sectors from _full.bin: _cd.zip only the 2048 bytes before them
GAP = 150                 # the 2 s between the data track and the music: the core's audio is LBA - 150 in the image


def full_image(tr, b, full, cooked, at16):
    """The whole-disc image from extractcd's bin: the data track (a 2048-byte sector padded to 2352: its data at 0, or at 16 as a
    raw sector's), then each audio sector at (its LBA - GAP) x 2352: a pregap the CHD keeps before the first audio track is left out
    (it would land on the data track), one it doesn't keep later on is zeros. True if that's extractcd's file as it is (padded)."""
    plain = True
    with open(b, 'rb') as f, open(full + '.tmp', 'wb') as o:
        for _ in range(tr[0][2]):
            s = f.read(2048 if cooked else 2352)
            if len(s) != (2048 if cooked else 2352):
                sys.exit(f'{b}: the extracted disc ends inside its data track')
            o.write((bytes(16) + s + bytes(288) if at16 else s + bytes(304)) if cooked else s)
        lba = tr[0][2]
        for n, typ, frames, pregap, stored in tr[1:]:
            if not stored:
                lba += pregap
            want, at = (lba - GAP) * 2352, o.tell()
            skip = 0
            if at > want:                    # the first audio track's stored pregap, over the data track's end
                skip = (at - want) // 2352
                if not stored or skip > pregap:
                    sys.exit(f'track {n} would start inside the data track')
                f.seek(skip * 2352, 1)
                plain = False
            elif at < want:
                o.write(bytes(want - at))
                plain = False
            left = (frames - skip) * 2352
            while left:
                s = f.read(min(left, 1 << 20))
                if not s:
                    sys.exit(f'{b}: ends inside track {n}')
                o.write(s)
                left -= len(s)
            lba += frames
        if f.read(1):
            sys.exit(f'{b}: more than the tracks')
    os.replace(full + '.tmp', full)
    return plain


def full_cue(tr, full):
    """A cue sheet for full_image's layout: each track at its INDEX 01"""
    lines = ['FILE "%s" BINARY' % full, '  TRACK 01 MODE1/2352', '    INDEX 01 00:00:00']
    lba = tr[0][2]
    for n, typ, frames, pregap, stored in tr[1:]:
        lba += pregap if not stored else 0
        at = lba + (pregap if stored else 0) - GAP
        lines += ['  TRACK %02d %s' % (n, typ), '    INDEX 01 %02d:%02d:%02d' % (at // 4500, at // 75 % 60, at % 75)]
        lba += frames
    return '\n'.join(lines) + '\n'


def main(chd, chdman='chdman'):
    tr = cdimage.toc(chdman, chd)
    key = (len(tr), tr[0][2])
    if key not in DISCS:
        sys.exit(f'{chd}: {key[0]} tracks, a data track of {key[1]} sectors: not 623jaa02, 810uba02, 810eaa02, 639eba01, 703eaa02'
                 ' or 636jac02')
    names = DISCS[key]
    names = (names,) if isinstance(names, str) else names
    cooked = tr[0][1] == 'MODE1'
    print(f'{chd}: {" or ".join(names)}, data track {tr[0][1]}' + (' (2048-byte sectors, padded to 2352)' if cooked else ''))
    # a CHD without the 2 s before the first audio track (some of Heat of Eleven's and Battle Tryst's): put back, as the disc has
    # it, where its table of contents and the image place the music (the core can't play a track that starts before it)
    n2, typ2, frames2, pregap2, stored2 = tr[1]
    fixed = False
    if pregap2 < GAP:
        if stored2:
            sys.exit(f'{chd}: track 2 keeps only {pregap2} sectors before it')
        tr[1] = (n2, typ2, frames2, GAP, False)
        fixed = True
        print(f'  no {GAP}-sector gap before track 2 in this CHD (not MAME\'s?): put back')
    with tempfile.TemporaryDirectory(dir='.') as d:
        cue, b = cdimage.extract(chdman, chd, d)

        cd = os.path.join(d, 'disc_cd.bin')
        cdimage.write(tr, b, cd)
        whole, sectors = hashlib.sha256(), hashlib.sha256()   # the data image's, and its data sectors' (from 2048 on)
        with open(cd, 'rb') as f:
            s = f.read(2048)
            whole.update(s)
            for s in iter(lambda: f.read(1 << 20), b''):
                whole.update(s)
                sectors.update(s)
        whole, sectors = whole.hexdigest(), sectors.hexdigest()

        def wanted(n):
            return SECTORS_SHA256[n] + (sectors,) if n in SECTORS_SHA256 else DATA_SHA256[n] + (whole,)
        name = next((n for n in names if wanted(n)[1] == wanted(n)[2]), None)
        if name is None:
            want = ' or '.join(wanted(n)[0] for n in names)
            sys.exit(f'{chd}: has the layout of {want}, but not its data: another version of the disc (Total Vice: AAB, JAD or UAC?).'
                     f' The core runs only {want}. (Data image SHA-256 {whole}, its sectors\' {sectors}.)')
        print(f'  {name}')
        if name in STREAMED:
            with open(cd, 'r+b') as f:
                f.truncate(2048)
        with zipfile.ZipFile(name + '_cd.zip', 'w', zipfile.ZIP_DEFLATED) as z:
            z.write(cd, name + '_cd.bin')
        print(name + '_cd.zip' + (' (the 2048 bytes before the sectors)' if name in STREAMED else ''))

        full = name + '_full.bin'
        plain = full_image(tr, b, full, cooked, name in STREAMED) and not fixed
        if plain:
            with open(cue) as f:
                text = f.read()
            text = re.sub(r'FILE "[^"]*"', 'FILE "' + full + '"', text).replace('MODE1/2048', 'MODE1/2352')
        else:
            text = full_cue(tr, full)
        with open(name + '_full.cue', 'w') as f:
            f.write(text)
        print(full, os.path.getsize(full), 'bytes, and', name + '_full.cue')

    if name == 'polystar':
        cdfix.main(full, full)


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    main(*sys.argv[1:])
