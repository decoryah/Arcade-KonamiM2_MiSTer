#!/usr/bin/env python3
"""m2fps.py: runs on the MiSTer. An M2_FPS build's frame rate (rtl/m2_fps.sv): once a second the core writes an entry to a ring of
4096 64-bit entries at DDR3 0x30800000: {0xF5, the second mod 256, frames, flips, CPU 1's instructions / 4096, CPU 2's}.
  m2fps.py clear           zero the ring (before loading the core: entry 0 is then its first second)
  m2fps.py watch [FILE]    print each second as it comes (and append it to FILE), until interrupted
  m2fps.py dump [FILE]     every second in the ring, oldest first (or from a saved copy of the 32 KB)
  m2fps.py save FILE       copy the ring (32 KB)
  m2fps.py sum A B [FILE]  flips a second over the core's seconds A to B (from its start: entry 0 is second 0), and the CPUs' MIPS
A flip is a frame whose shown buffers differ from the frame before's: the game's frame rate."""
import mmap, os, struct, sys, time
BASE = 0x30800000
N = 4096

def ring(rw=False):
    f = os.open('/dev/mem', (os.O_RDWR if rw else os.O_RDONLY) | os.O_SYNC)
    return mmap.mmap(f, N * 8, mmap.MAP_SHARED, mmap.PROT_READ | (mmap.PROT_WRITE if rw else 0), offset=BASE)

def load(fn=None):
    return open(fn, 'rb').read() if fn else ring()[:]

def entries(b):
    """(index, second, frames, flips, MIPS 1, MIPS 2) for each written entry, in the order written"""
    e = struct.unpack('<%dQ' % N, b)
    out = []
    for i, x in enumerate(e):
        if (x >> 56) != 0xf5:
            continue
        out.append((i, (x >> 48) & 0xff, (x >> 40) & 0xff, (x >> 32) & 0xff, ((x >> 16) & 0xffff) * 4096 / 1e6, (x & 0xffff) * 4096 / 1e6))
    # (in ring order: entry i is the core's second i. The ring holds 4096 seconds (68 minutes); past that it wraps and, 4096 being a
    # multiple of 256, the seconds can't tell where: clear it before each load and read it within the hour)
    return out

def line(t):
    i, s, fr, fl, m1, m2 = t
    return '%4d  second %3d  frames %3d  flips %3d  CPU1 %6.2f MIPS  CPU2 %6.2f MIPS' % (i, s, fr, fl, m1, m2)

def main():
    a = sys.argv[1:] or ['dump']
    if a[0] == 'clear':
        m = ring(True)
        m[0:N * 8] = bytes(N * 8)
        print('cleared')
    elif a[0] == 'save':
        open(a[1], 'wb').write(load())
        print('saved', a[1])
    elif a[0] == 'dump':
        for t in entries(load(a[1] if len(a) > 1 else None)):
            print(line(t))
    elif a[0] == 'sum':
        lo, hi = int(a[1]), int(a[2])
        es = entries(load(a[3] if len(a) > 3 else None))[lo:hi + 1]
        if not es:
            print('no seconds there')
            return
        n = len(es)
        print('seconds %d-%d (%d): flips %.2f a second (min %d, max %d), frames %.2f; CPU1 %.2f MIPS, CPU2 %.2f MIPS' % (
            lo, hi, n, sum(t[3] for t in es) / n, min(t[3] for t in es), max(t[3] for t in es), sum(t[2] for t in es) / n,
            sum(t[4] for t in es) / n, sum(t[5] for t in es) / n))
    elif a[0] == 'watch':
        out = open(a[1], 'a') if len(a) > 1 else None
        seen = set()
        while True:
            for t in entries(load()):
                k = (t[0], t[1])
                if k not in seen:
                    seen.add(k)
                    s = time.strftime('%H:%M:%S ') + line(t)
                    print(s, flush=True)
                    if out:
                        out.write(s + '\n'); out.flush()
            time.sleep(1)
    else:
        print(__doc__)

main()
