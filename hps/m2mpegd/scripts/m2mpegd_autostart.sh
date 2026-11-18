#!/bin/sh
# m2mpegd_autostart.sh (in /media/fat/Scripts): turns the MPEG daemon's auto-start on or off. On: a line in
# /media/fat/linux/user-startup.sh starts it at every boot, so Battle Tryst's movies play however the game is loaded, and it
# starts now. Off: the line is removed and the daemon stops (Battle_Tryst_MPEG.sh still works).
# While another core runs, the daemon only reads /tmp/CORENAME once a second.
U=/media/fat/linux/user-startup.sh
S=/media/fat/m2mpegd/m2mpegd_service.sh
LINE="[[ -e $S ]] && $S \$1   # m2mpegd (Battle Tryst MPEG)"

if [ -f "$U" ] && grep -q "m2mpegd_service.sh" "$U"; then
  cp "$U" "$U.bak_m2mpegd"
  grep -v -e "m2mpegd_service.sh" -e "m2mpegd_autostart.sh" "$U.bak_m2mpegd" > "$U"
  $S stop
  echo "MPEG daemon auto-start: OFF"
else
  [ -f "$U" ] || printf '#!/bin/sh\n' > "$U"
  cp "$U" "$U.bak_m2mpegd"
  [ -n "$(tail -c 1 "$U")" ] && echo >> "$U"   # (the file's last line ended, so ours stays a line of its own)
  printf '# Battle Tryst MPEG daemon (m2mpegd_autostart.sh adds and removes this line)\n%s\n' "$LINE" >> "$U"
  $S start
  echo "MPEG daemon auto-start: ON"
fi
