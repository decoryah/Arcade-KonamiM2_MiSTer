#!/bin/sh
# Battle_Tryst_MPEG.sh (in /media/fat/Scripts): Battle Tryst with its movies. Starts the MPEG daemon for this one session,
# then loads the game. The daemon leaves by itself when another core is loaded (or if the game doesn't load within a
# minute). Loading Battle Tryst's MRA from the Arcade menu instead shows black movies, unless auto-start is on
# (m2mpegd_autostart.sh).
# MRA: by default the most recently copied "Battle Tryst*.mra" in /media/fat/_Arcade (the release's is
# "Battle Tryst (ver JAC).mra"). To always load one MRA, put its full path here, e.g.
# MRA="/media/fat/_Arcade/Battle Tryst (ver JAC).mra"
MRA=""
if [ -z "$MRA" ]; then
  MRA=$(ls -t /media/fat/_Arcade/Battle\ Tryst*.mra 2>/dev/null | head -n 1)
fi
if [ -z "$MRA" ] || [ ! -f "$MRA" ]; then
  echo "No Battle Tryst MRA found in /media/fat/_Arcade"
  exit 1
fi
/media/fat/m2mpegd/m2mpegd_service.sh start once || exit 1
echo "Loading $MRA"
echo "load_core $MRA" > /dev/MiSTer_cmd
