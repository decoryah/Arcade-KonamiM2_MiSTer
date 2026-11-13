#!/usr/bin/env python3
"""Compile one of the core's builds with Quartus Prime Lite 17.0 (quartus_sh on the PATH) and put its RBF in releases/:

  python3 tools/build.py [default|heat|tryst] [--seed N] [--date YYYYMMDD[a-z]] [--threads N] [--force]

  default   releases/KonamiM2_<date>.rbf        the MRAs that ask for KonamiM2
  heat      releases/KonamiM2Heat_<date>.rbf    Heat of Eleven '98's MRA (KonamiM2.qsf's Heat of Eleven lines)
  tryst     releases/KonamiM2Tryst_<date>.rbf   Battle Tryst's MRA (KonamiM2.qsf's Battle Tryst lines)
  hellngt   releases/KonamiM2HellNight_<date>.rbf  Hell Night's MRA (KonamiM2.qsf's Hell Night lines)

The repository's files (git ls-files, as they are in the working tree) are copied to build/<build>_<date>_s<seed>/, and its
KonamiM2.qsf there gets the build's lines (uncommented, with the build's seed in place of the default's); the repository's own
qsf isn't touched. The fitter and timing summaries go beside the RBF (<name>_<date>.fit.summary, .sta.summary). A build that
misses timing on any clock isn't put in releases/ unless --force; an RBF already there isn't replaced unless --force. With no
date, today's. The build folder stays (Quartus's reports, compile.log): delete it when done.
"""
import argparse
import datetime
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# the build: (the RBF's name, the first line of its block in KonamiM2.qsf; none for the default)
BUILDS = {
    'default': ('KonamiM2', None),
    'heat': ('KonamiM2Heat', "# Heat of Eleven's build:"),
    'tryst': ('KonamiM2Tryst', "# Battle Tryst's build:"),
    'hellngt': ('KonamiM2HellNight', "# Hell Night's build:"),
}
SEED = re.compile(r'^set_global_assignment -name SEED (\d+)\s*$')


def qsf_for(text, header, seed):
    """KonamiM2.qsf with the block that starts at header (to the next blank line) uncommented, and one seed: the given one, else
    the block's, else the qsf's own"""
    lines = text.split('\n')
    if header:
        starts = [i for i, l in enumerate(lines) if l.startswith(header)]
        if len(starts) != 1:
            sys.exit('KonamiM2.qsf: %d lines start with "%s"' % (len(starts), header))
        i = starts[0]
        while i < len(lines) and lines[i].strip():
            if lines[i].startswith('#set_global_assignment'):
                lines[i] = lines[i][1:]
            i += 1
    seeds = [i for i, l in enumerate(lines) if SEED.match(l)]
    if seed is None:
        if not seeds:
            sys.exit('KonamiM2.qsf: no seed')
        seed = int(SEED.match(lines[seeds[-1]]).group(1))   # (the block's comes after the default's)
    for i in seeds:
        lines[i] = '#' + lines[i]
    lines.append('set_global_assignment -name SEED %d' % seed)
    return '\n'.join(lines) + '\n', seed


def slacks(sta):
    """{(the check, the clock): the worst slack} from a .sta.summary"""
    text = open(sta, errors='replace').read()
    return {(k, c): float(v) for k, c, v in re.findall(r"Type  : (\S+) '([^']+)'\nSlack : (-?[\d.]+)", text)}


def main():
    ap = argparse.ArgumentParser(description='Compile one of the core\'s builds into releases/.')
    ap.add_argument('build', nargs='?', default='default', choices=sorted(BUILDS))
    ap.add_argument('--seed', type=int, help="the fitter's seed (default: the build's in KonamiM2.qsf)")
    ap.add_argument('--date', default=datetime.date.today().strftime('%Y%m%d'), help='the RBF\'s date (default: today)')
    ap.add_argument('--threads', type=int, help="Quartus's processors (NUM_PARALLEL_PROCESSORS)")
    ap.add_argument('--force', action='store_true', help='put the RBF in releases/ even if it misses timing or one is there')
    a = ap.parse_args()
    if not re.fullmatch(r'\d{8}[a-z]?', a.date):
        sys.exit('--date: YYYYMMDD or YYYYMMDD and a letter')
    name, header = BUILDS[a.build]
    if shutil.which('quartus_sh') is None:
        sys.exit('quartus_sh is not on the PATH (Quartus Prime Lite 17.0: <quartus>/bin)')

    with open(os.path.join(REPO, 'KonamiM2.qsf'), newline='') as f:
        qsf, seed = qsf_for(f.read().replace('\r\n', '\n'), header, a.seed)
    out = os.path.join(REPO, 'build', '%s_%s_s%d' % (a.build, a.date, seed))
    if os.path.exists(out):
        sys.exit('%s is there from an earlier build: delete it, or give another --date or --seed' % out)
    files = subprocess.run(['git', '-C', REPO, 'ls-files', '-z'], capture_output=True, check=True).stdout.decode().split('\0')
    for p in files:
        if p and os.path.isfile(os.path.join(REPO, p)):
            os.makedirs(os.path.join(out, os.path.dirname(p)), exist_ok=True)
            shutil.copy2(os.path.join(REPO, p), os.path.join(out, p))
    if a.threads:
        qsf += 'set_global_assignment -name NUM_PARALLEL_PROCESSORS %d\n' % a.threads
    with open(os.path.join(out, 'KonamiM2.qsf'), 'w', newline='\n') as f:
        f.write(qsf)
    print('%s, seed %d, in %s' % (name, seed, out))

    log = os.path.join(out, 'compile.log')
    with open(log, 'w') as lf:
        p = subprocess.Popen(['quartus_sh', '--flow', 'compile', 'KonamiM2'], cwd=out, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, errors='replace')
        for line in p.stdout:
            lf.write(line)
            if line.startswith('Error') or 'Running Quartus Prime' in line:
                print(' ', line.rstrip())
        p.wait()
    if p.returncode:
        sys.exit('quartus_sh failed (exit %d): see %s' % (p.returncode, log))

    of = os.path.join(out, 'output_files', 'KonamiM2')
    s = slacks(of + '.sta.summary')
    bad = {k: v for k, v in s.items() if v < 0}
    for (k, c), v in sorted(s.items(), key=lambda kv: kv[1])[:4]:
        print('  %-8s %8.3f  %s' % (k, v, c))
    if bad:
        print('timing NOT met on %d check(s)' % len(bad))
    rel = os.path.join(REPO, 'releases', '%s_%s' % (name, a.date))
    if bad and not a.force:
        sys.exit('not put in releases/ (--force to put it there anyway): %s.rbf' % of)
    if os.path.exists(rel + '.rbf') and not a.force:
        sys.exit('%s.rbf is there already (--force to replace it): %s.rbf' % (rel, of))
    for ext in ('.rbf', '.fit.summary', '.sta.summary'):
        shutil.copyfile(of + ext, rel + ext)
    print(rel + '.rbf', os.path.getsize(rel + '.rbf'), 'bytes')


if __name__ == '__main__':
    main()
