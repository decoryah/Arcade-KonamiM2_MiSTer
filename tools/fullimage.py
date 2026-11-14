#!/usr/bin/env python3
"""Make the whole-disc image a game streams its data from (Battle Tryst), from chdman's extractcd output:

  chdman extractcd -i <game.chd> -o x.cue -ob x.bin
  python3 tools/fullimage.py x.cue <set>_full.bin

The image has the data track whole, raw (2352 bytes a sector, the data at 16 in), so a data sector LBA n is at n * 2352, as
rtl/m2_atapi.sv streams it; then the audio tracks, without the first one's pregap (extractcd keeps it in the file, between that
track's INDEX 00 and INDEX 01), so an audio sector LBA n is at (n - 150) * 2352, as rtl/m2_cdda.sv reads it. It also writes the
.cue beside it (<set>_full.cue).
"""
import os
import re
import sys


def msf(s):
    m, sec, f = (int(x) for x in s.split(':'))
    return (m * 60 + sec) * 75 + f


def main(cue_in, out_bin):
    text = open(cue_in).read()
    files = re.findall(r'^FILE "([^"]+)"', text, re.M)
    if len(files) != 1:
        sys.exit('%s: expected one FILE, found %d' % (cue_in, len(files)))
    src = os.path.join(os.path.dirname(cue_in), files[0])
    tracks = []
    for m in re.finditer(r'TRACK (\d+) (\S+)((?:\s+INDEX \d+ [\d:]+)+)', text):
        idx = {int(i): msf(t) for i, t in re.findall(r'INDEX (\d+) ([\d:]+)', m.group(3))}
        tracks.append((int(m.group(1)), m.group(2), idx))
    if not tracks or tracks[0][1] != 'MODE1/2352':
        sys.exit('%s: the first track must be MODE1/2352 (raw data), not %s' % (cue_in, tracks[0][1] if tracks else 'none'))
    if len(tracks) < 2:
        sys.exit('%s: no audio track' % cue_in)
    n2, typ2, idx2 = tracks[1]
    if typ2 != 'AUDIO' or 0 not in idx2 or 1 not in idx2:
        sys.exit('%s: track 2 is not audio with INDEX 00 and 01' % cue_in)
    cut0, cut1 = idx2[0], idx2[1]
    gap = cut1 - cut0
    if gap != 150:
        print('note: track 2 pregap is %d sectors, not 150' % gap)
    size = os.path.getsize(src)
    if size % 2352:
        sys.exit('%s: %d bytes, not whole 2352-byte sectors' % (src, size))
    with open(src, 'rb') as f, open(out_bin + '.tmp', 'wb') as o:
        left = cut0 * 2352
        while left:
            b = f.read(min(left, 1 << 20))
            if not b:
                sys.exit('%s: ends before track 2' % src)
            o.write(b)
            left -= len(b)
        f.seek(cut1 * 2352)
        for b in iter(lambda: f.read(1 << 20), b''):
            o.write(b)
    os.replace(out_bin + '.tmp', out_bin)
    # the cue: each track at INDEX 01, those after the cut moved up by it
    lines = ['FILE "%s" BINARY' % os.path.basename(out_bin)]
    for n, typ, idx in tracks:
        at = idx[1] if 1 in idx else idx[min(idx)]
        if at >= cut1:
            at -= gap
        elif n == n2:
            at = cut0
        lines.append('  TRACK %02d %s' % (n, typ))
        lines.append('    INDEX 01 %02d:%02d:%02d' % (at // 4500, at // 75 % 60, at % 75))
    cue_out = os.path.splitext(out_bin)[0] + '.cue'
    open(cue_out, 'w', newline='\n').write('\n'.join(lines) + '\n')
    print(out_bin, os.path.getsize(out_bin), 'bytes; data track', cut0, 'sectors; the pregap cut:', gap, 'sectors;', cue_out)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
