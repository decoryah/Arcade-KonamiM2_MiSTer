#!/usr/bin/env python3
"""Build the CD image rtl/m2_atapi.sv reads, from a game's MAME CHD:

  python3 tools/cdimage.py <chdman> <game.chd> <out.bin>

The image: 2048 bytes of what the drive answers that isn't a sector (the TOC from the CHD; IDENTIFY, REQUEST SENSE and MODE SENSE as
MAME's CR-589 gives them, captured), then the sectors of the first track, the data track, 2048 bytes each. The audio tracks aren't
in it (the TOC still lists them). Zip it as <set>_cd.zip with the name in the MRA, beside the set's zip on the SD card.
"""
import os
import re
import struct
import subprocess
import sys
import tempfile

IDENTIFY = bytes.fromhex(
    '0085' + '00' * 44 + '2e31203020202020' + '414d5354494841544320' + '2d52383520392020' + '20' * 22 + '0000000000040000'
)
IDENTIFY = IDENTIFY + bytes(512 - len(IDENTIFY))
SENSE = bytes.fromhex('700000000000000a000000000000')
MODE = bytes.fromhex('00160300000000008e0e04000000000001ff02ff04ff08ff')


def toc(chdman, chd):
    out = subprocess.run([chdman, 'info', '-v', '-i', chd], capture_output=True, text=True).stdout
    tracks = []
    for m in re.finditer(r'TRACK:(\d+) TYPE:(\S+) SUBTYPE:\S+ FRAMES:(\d+)(?: PREGAP:(\d+))?', out):
        tracks.append((int(m.group(1)), m.group(2), int(m.group(3)), int(m.group(4) or 0)))
    if not tracks:
        sys.exit('no tracks in ' + chd)
    return tracks


def main(chdman, chd, outf):
    tr = toc(chdman, chd)
    # the LBAs as MAME's CD gives them: frames in order, a track's pregap before it (the CHD's frames count from the pregap's
    # end for these sets)
    lba, ent = 0, []
    for n, typ, frames, pregap in tr:
        lba += pregap
        ent.append((n, typ, lba))
        lba += frames
    last = tr[-1][0]
    info = bytearray(2048)
    info[0:512] = IDENTIFY
    info[0x200:0x200 + len(SENSE)] = SENSE
    info[0x220:0x220 + len(MODE)] = MODE
    info[0x240:0x248] = struct.pack('>II', lba - 1, 2048)

    def entry(start_i, n, ctrl, l):
        size = 2 + (last - start_i + 2) * 8
        return struct.pack('>HBBBBBBI', size, 1, last, 0, ctrl, n, 0, l)
    for i, (n, typ, l) in enumerate(ent):
        ctrl = 0x10 if typ == 'AUDIO' else 0x14
        info[0x400 + 16 * n:0x400 + 16 * n + 12] = entry(n, n, ctrl, l)
    info[0x400 + 16 * 0x3f:0x400 + 16 * 0x3f + 12] = struct.pack('>HBBBBBBI', 10, 1, last, 0, 0x10, 0xaa, 0, lba)

    # (the directory beside the image, and paths as given, so a Windows chdman from WSL finds them)
    with tempfile.TemporaryDirectory(dir=os.path.dirname(outf) or '.') as d:
        d = os.path.relpath(d).replace(os.sep, '/')
        cue, b = d + '/x.cue', d + '/x.bin'
        subprocess.run([chdman, 'extractcd', '-i', chd, '-o', cue, '-ob', b, '-f'], check=True, capture_output=True)
        frames = tr[0][2]
        with open(b, 'rb') as f, open(outf, 'wb') as o:
            o.write(info)
            for _ in range(frames):
                s = f.read(2352)
                o.write(s[16:2064])
    print(outf, 2048 * (frames + 1), 'bytes;', len(tr), 'tracks, lead-out', lba)


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
