#!/usr/bin/env python3
"""Fill the gaps in Polystars' music: repair the disc image chdman extractcd makes from MAME's 623jaa02.chd (marked BAD_DUMP):

  python3 tools/cdfix.py polystar_full.bin [out.bin]

With one file it is repaired in place; with two the repair is written to the second. The dump has 28 stretches of exactly 26
sectors (0.35 s) of digital silence in its music, where the ripper's reads failed: 16 in the stage 7 boss's music, the rest one or
two in other tracks (the first, stage 1's, 9 s in). Each is filled from the passage of the same track whose surroundings match
it best (the music repeats), crossfaded over XF samples at each end. The table holds only positions: all the audio comes from
the image itself. A file that isn't this image, or is already repaired, is left alone.
"""
import os
import sys
import zlib
from array import array

L = 26 * 588   # a hole, in stereo samples
XF = 256       # crossfade, in samples
SIZE = 545835696
AUDIO = 11928 * 2352       # where the music starts: after the data track, which a CHD may keep raw or as 2048-byte sectors (tools/m2disc.py pads those)
FIXED_CRC32 = 0x98c5a5be   # of the result's music
# hole's first sector, the first sample of the passage that fills it
TABLE = [
    (12630, 14145872),
    (27372, 22457696),
    (77760, 37837436),
    (84130, 52283964),
    (104462, 56859944),
    (132542, 76416507),
    (151054, 90129023),
    (164288, 95283442),
    (176144, 105799027),
    (181500, 102269269),
    (185660, 110446458),
    (186336, 108287163),
    (200220, 123553387),
    (200558, 121810820),
    (200714, 123843856),
    (201442, 122330630),
    (202014, 116842866),
    (203470, 123523013),
    (203860, 123752326),
    (203912, 116017517),
    (204354, 118218779),
    (204484, 118295206),
    (204848, 122391969),
    (205238, 116797192),
    (205680, 122881146),
    (205914, 117194666),
    (206564, 117576911),
    (206798, 123538549),
]


def samples(f, start, n):
    f.seek(start * 4)
    a = array('h', f.read(n * 4))
    if sys.byteorder == 'big':
        a.byteswap()
    return a


def main(src, dst):
    with open(src, 'rb') as f:
        f.seek(0, 2)
        if f.tell() != SIZE:
            sys.exit(f'{src}: {f.tell()} bytes, not {SIZE}: not the image chdman extractcd makes from 623jaa02.chd')
        for hole, _ in TABLE:
            if any(samples(f, hole * 588, L)):
                sys.exit(f'{src}: sector {hole} is not silent: not the 623jaa02 image, or already repaired')
        f.seek(0)
        data = bytearray(f.read())
    with open(src, 'rb') as f:
        for hole, s in TABLE:
            h = hole * 588
            a = samples(f, h - XF, L + 2 * XF)
            b = samples(f, s - XF, L + 2 * XF)
            out = array('h', bytes(len(a) * 2))
            for i in range(-XF, L + XF):
                w = (i + XF) / XF if i < 0 else (L + XF - i) / XF if i >= L else 1.0
                for ch in (0, 1):
                    k = 2 * (i + XF) + ch
                    out[k] = round((1 - w) * a[k] + w * b[k])
            if sys.byteorder == 'big':
                out.byteswap()
            data[(h - XF) * 4:(h + L + XF) * 4] = out.tobytes()
    tmp = dst + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.replace(tmp, dst)
    c = zlib.crc32(memoryview(data)[AUDIO:])
    print(f'{dst}: {len(TABLE)} holes filled, the music\'s CRC32 {c:08x}' + (' (as expected)' if c == FIXED_CRC32 else ' (NOT as expected)'))


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[-1])
