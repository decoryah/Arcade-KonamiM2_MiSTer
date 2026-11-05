#!/usr/bin/env python3
"""m2_report.py: summarise a capture made by tools/lua/m2_capture.lua.

    python tools/m2_report.py m2cap            # frames.csv, features.txt, and trace/ if present
    python tools/m2_report.py m2cap --top 30   # more render states

Prints:
  * per-frame load: TE lists, triangles, estimated pixels, texture loads, BDA traffic by unit
  * the render states by pixel share, with their fields decoded (filter, depth, blend, Z, colour depth)
  * from trace/: each CPU's instructions per frame, split into busy and idle-spin, against the 66.67 MHz budget
"""

import argparse
import csv
import os
import re
import statistics
import sys
from collections import Counter, deque

CPU_HZ = 66_666_700
FRAME_HZ = 59.94                       # NTSC (set_ntsc); the capture's own frame count is what matters
CYCLES_PER_FRAME = CPU_HZ / FRAME_HZ

STATE_NAMES = ["TEMasterMode", "TexCntl", "TexAddrCntl", "TexPIPCntl", "TexTabCntl", "TexExpType", "SuperGenCtrl",
               "UserGenCtrl", "DiscardCtrl", "DstCtrl", "SrcCtrl", "ZCtrl", "SSBDSBCtrl", "TxtMultCntl",
               "SrcMultCntl", "ALUCtrl", "SrcAlphaCtrl", "DstAlphaCtrl"]

FILTERS = ["point", "linear", "bilinear", "quasi-trilinear"]


def pct(a, b):
    return 100.0 * a / b if b else 0.0


def load_frames(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for k in r:
            r[k] = float(r[k]) if r[k] else 0.0
    return rows


def frame_report(rows):
    print("== Per-frame load ==")
    print(f"frames: {len(rows)}")
    busy = [r for r in rows if r["lists"] > 0]
    print(f"frames with TE lists: {len(busy)}")
    if not busy:
        return
    cols = ["lists", "list_words", "vertices", "triangles", "pixels_est", "texloads", "texload_bytes"]
    print(f"{'':16}{'mean':>12}{'p95':>12}{'max':>12}")
    for c in cols:
        v = sorted(r[c] for r in busy)
        p95 = v[min(len(v) - 1, int(len(v) * 0.95))]
        print(f"{c:16}{statistics.mean(v):12.0f}{p95:12.0f}{v[-1]:12.0f}")
    worst = max(busy, key=lambda r: r["pixels_est"])
    print(f"heaviest frame by pixels: {int(worst['frame'])} "
          f"({worst['triangles']:.0f} triangles, {worst['pixels_est']:.0f} pixels)")
    # The TE's fill budget at one pixel a clock and 66.67 MHz, against the heaviest frame
    print(f"  at 1 pixel/clock, 66.67 MHz: {pct(worst['pixels_est'], CYCLES_PER_FRAME):.1f}% of a frame "
          f"(no overdraw from Z or blending reads counted)")
    print()
    # the columns after texload_bytes: each unit's accesses (_w writes, _r reads, _rw both), as the debugger counted them
    print("BDA traffic (CPU accesses per frame, mean / max):")
    names = list(rows[0])
    for c in names[names.index("texload_bytes") + 1:]:
        v = [r[c] for r in rows]
        print(f"  {c:12} " + ("unused" if max(v) == 0 else f"{statistics.mean(v):10.0f} / {max(v):10.0f}"))
    print()


def decode_state(vals, vf):
    v = dict(zip(STATE_NAMES, vals))
    out = []
    mm = v["TEMasterMode"]
    disabled = [n for b, n in [(0x02, "tex"), (0x04, "shade"), (0x08, "blend"), (0x10, "z"), (0x20, "dither")] if mm & b]
    if disabled:
        out.append("master-off:" + "/".join(disabled))
    flags = [n for b, n in [(1, "shade"), (2, "tex"), (4, "persp")] if vf & b]
    out.append("vtx:" + ("+".join(flags) or "flat"))
    if vf & 2:
        ac = v["TexAddrCntl"]
        out.append(f"filter:{FILTERS[ac & 3]}/{FILTERS[(ac >> 4) & 3]}/{FILTERS[(ac >> 7) & 3]}/{FILTERS[(ac >> 10) & 3]}")
        out.append(f"lodmax:{ac & 0xf}")
        if ac & 0x2000:
            out.append("lookup(PIP)")
        et = v["TexExpType"]
        out.append(f"texel:c{et & 0xf}a{(et >> 4) & 0xf}" + ("+ssb" if et & 0x200 else "") +
                   ("+literal" if et & 0x1000 else "") + ("+color" if et & 0x400 else ""))
    ug = v["UserGenCtrl"]
    out.append("db:" + "/".join(n for b, n in [(0x10, "dither"), (0x20, "srcin"), (0x40, "blend"), (0x80, "wclipout"),
                                                (0x100, "wclipin"), (0x200, "zout"), (0x400, "zbuf")] if ug & b))
    out.append("dst:" + ("32bpp" if v["DstCtrl"] & 1 else "16bpp"))
    if ug & 0x20:
        out.append("src:" + ("32bpp" if v["SrcCtrl"] & 1 else "16bpp"))
    if ug & 0x400:
        out.append(f"zfunc:{v['ZCtrl'] & 0x3f:02x}")
    if ug & 0x40:
        out.append(f"alu:{(v['ALUCtrl'] >> 5) & 0x1f:02x}")
    if v["DiscardCtrl"]:
        out.append(f"discard:{v['DiscardCtrl'] & 0xf:x}")
    return " ".join(out)


def features_report(path, top):
    print("== Render states by estimated pixels ==")
    states = []
    with open(path) as f:
        text = f.read()
    sect = text.split("== Render states")[1].split("== Register values")[0]
    for line in sect.splitlines():
        m = re.match(r"\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+) : (.*) vf=([0-9a-f]+)", line)
        if m:
            vals = [int(x, 16) for x in m.group(5).split()]
            states.append((int(m.group(1)), int(m.group(2)), int(m.group(4)), vals, int(m.group(6), 16)))
    total_px = sum(s[1] for s in states) or 1
    total_tri = sum(s[0] for s in states) or 1
    print(f"{len(states)} distinct states, {total_tri} triangles")
    print(f"{'pix%':>6} {'tri%':>6} {'frames':>7}  decoded")
    for tris, px, frames, vals, vf in states[:top]:
        print(f"{pct(px, total_px):6.1f} {pct(tris, total_tri):6.1f} {frames:7d}  {decode_state(vals, vf)}")
    # Feature totals: what the TE must implement, weighted by pixels
    feat = Counter()
    for tris, px, frames, vals, vf in states:
        seen = set()
        for tok in decode_state(vals, vf).split():
            for part in tok.split(":", 1)[1].split("/") if ":" in tok else [tok]:
                seen.add((tok.split(":")[0], part))
        for k in seen:
            feat[k] += px
    print()
    print("Features by pixel share (anything above 0 has to be in the TE):")
    for (k, p), px in sorted(feat.items(), key=lambda x: -x[1]):
        if k in ("filter", "texel", "vtx", "db", "dst", "src", "master-off", "zfunc", "alu", "discard", "lodmax"):
            print(f"  {k:10} {p:20} {pct(px, total_px):6.1f}%")
    print()
    rest = text.split("== Register values written (name: value x count) ==")[1]
    odd = rest.split("== Oddities ==")[1].strip()
    print("== Oddities ==")
    print(odd or "none")
    print()
    for want in ("TexLoad compressed", "TexLoad mode", "TEDCntl SYNC", "TEDCntl PSE", "TEDCntl JA", "TEDCntl JR"):
        for line in rest.splitlines():
            if line.startswith(want + ":"):
                print(line)
    print()


# ---- traces ------------------------------------------------------------------------------------------------------

TRACE_LINE = re.compile(r"^\s*([0-9A-Fa-f]{8}):\s*(\S+)")
STORE = re.compile(r"^(st|dcb|stfs|stfd|stw|sth|stb|stm)", re.I)


def analyse_trace(path, max_period=32, min_iters=64):
    """Instructions in the file, and how many of them are spin loops with no stores in their body."""
    pcs = deque(maxlen=max_period * 2 + 2)
    mnem = {}
    total = 0
    idle = 0
    run = 0
    period = 0
    run_body_stores = False

    def close_run():
        nonlocal idle
        if period and run >= min_iters * period and not run_body_stores:
            idle += run

    with open(path, errors="replace") as f:
        for line in f:
            m = TRACE_LINE.match(line)
            if not m:
                continue
            pc = int(m.group(1), 16)
            mnem[pc] = m.group(2)
            total += 1
            h = pcs
            n = len(h)
            if period and n >= period and h[-period] == pc:
                run += 1
                if STORE.match(mnem[pc]):
                    run_body_stores = True
            else:
                close_run()
                run, period, run_body_stores = 0, 0, False
                for p in range(1, min(max_period, n) + 1):
                    if h[-p] == pc and (p + 1 > n or h[-p - 1] == h[-1]):
                        period = p
                        run = 1
                        run_body_stores = bool(STORE.match(mnem[pc]))
                        break
            pcs.append(pc)
    close_run()
    return total, idle


def trace_report(tdir):
    files = sorted(f for f in os.listdir(tdir) if f.endswith(".tr"))
    if not files:
        return
    print("== CPU load from traces ==")
    print(f"budget: {CYCLES_PER_FRAME:,.0f} cycles a frame per CPU at 66.67 MHz")
    print(f"{'file':28}{'instructions':>14}{'idle spin':>12}{'busy':>12}{'busy % at 1 CPI':>17}")
    per_cpu = {}
    for fn in files:
        total, idle = analyse_trace(os.path.join(tdir, fn))
        busy = total - idle
        cpu = fn.split("_f")[0]
        per_cpu.setdefault(cpu, []).append(busy)
        print(f"{fn:28}{total:14,}{idle:12,}{busy:12,}{pct(busy, CYCLES_PER_FRAME):16.1f}%")
    print()
    for cpu, b in per_cpu.items():
        print(f"{cpu}: busy instructions a frame mean {statistics.mean(b):,.0f}, max {max(b):,.0f}"
              f" -> a core at CPI c needs c x {max(b) / CYCLES_PER_FRAME:.2f} of the frame")
    print("(MAME's PPC602 timing is approximate: these are instruction counts, the work the game asks for.)")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capdir")
    ap.add_argument("--top", type=int, default=15)
    a = ap.parse_args()
    fp = os.path.join(a.capdir, "frames.csv")
    if not os.path.exists(fp):
        sys.exit(f"no frames.csv in {a.capdir}")
    frame_report(load_frames(fp))
    ff = os.path.join(a.capdir, "features.txt")
    if os.path.exists(ff):
        features_report(ff, a.top)
    td = os.path.join(a.capdir, "trace")
    if os.path.isdir(td):
        trace_report(td)


if __name__ == "__main__":
    main()
