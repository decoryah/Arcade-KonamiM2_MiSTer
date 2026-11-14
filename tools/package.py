#!/usr/bin/env python3
"""Build the release zip in MiSTer's SD card structure from the repository (as Gaelco 3D's tools/package.py):

  _Arcade/<title>.mra                   the MRAs                (mra/*.mra that ask for KonamiM2, or for a game's own build below)
  _Arcade/cores/KonamiM2_<date>.rbf     the core                (releases/KonamiM2_<date>.rbf)
  _Arcade/cores/KonamiM2Heat_<date>.rbf, KonamiM2Tryst_<date>.rbf, KonamiM2HellNight_<date>.rbf
                                        Heat of Eleven's, Battle Tryst's and Hell Night's own builds, if releases/ has them for
                                        the date (tools/build.py heat, tryst, hellngt); their MRAs only with them

  python3 tools/package.py [YYYYMMDD[a-z]]

Writes dist/KonamiM2_MiSTer_<date>.zip (dist/ holds only the release notes in the repository); with no date, the newest
release. Unzip over the root of the SD card.
"""
import glob
import os
import re
import sys
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main(argv):
    rbfs = sorted(r for r in glob.glob(os.path.join(REPO, 'releases', 'KonamiM2_*.rbf'))
                  if re.search(r'KonamiM2_\d{8}[a-z]?\.rbf$', r))
    if argv:
        rbfs = [r for r in rbfs if os.path.basename(r) == 'KonamiM2_%s.rbf' % argv[0]]
    if not rbfs:
        sys.exit('no such release in releases/')
    rbf = rbfs[-1]
    date = re.search(r'KonamiM2_(.+)\.rbf$', rbf).group(1)
    # the games' own builds of the same date, if made
    own = [r for r in (os.path.join(REPO, 'releases', '%s_%s.rbf' % (b, date)) for b in ('KonamiM2Heat', 'KonamiM2Tryst', 'KonamiM2HellNight'))
           if os.path.exists(r)]
    names = ['KonamiM2'] + [re.search(r'(KonamiM2\w+)_', os.path.basename(r)).group(1) for r in own]
    out = os.path.join(REPO, 'dist', 'KonamiM2_MiSTer_%s.zip' % date)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for mra in sorted(glob.glob(os.path.join(REPO, 'mra', '*.mra'))):
            with open(mra, encoding='utf-8') as f:
                if re.search(r'<rbf>(\w+)</rbf>', f.read()).group(1) not in names:
                    continue
            z.write(mra, '_Arcade/' + os.path.basename(mra))
        for r in [rbf] + own:
            z.write(r, '_Arcade/cores/' + os.path.basename(r))
    print(out)
    for n in zipfile.ZipFile(out).namelist():
        print(' ', n)


if __name__ == '__main__':
    main(sys.argv[1:])
