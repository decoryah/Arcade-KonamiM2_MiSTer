#!/bin/sh
# m2mpegd_autostart_on.sh (in /media/fat/Scripts): Battle Tryst's movies on. A line in /media/fat/linux/user-startup.sh
# starts the MPEG daemon at every boot, so the movies play however and from wherever the game's MRA is loaded, and it starts
# now. Run again, it changes nothing; m2mpegd_autostart_off.sh turns the movies off.
# While another core runs, the daemon sleeps, at normal priority, and reads /tmp/CORENAME once a second.
# It goes back to the menu by itself: on a CRT without the scaler MiSTer shows its MiSTer.ini notice instead of this
# console, so the "Press any key" there can't be seen.
U=/media/fat/linux/user-startup.sh
S=/media/fat/m2mpegd/m2mpegd_service.sh
LINE="[[ -e $S ]] && $S \$1   # m2mpegd (Battle Tryst MPEG)"

# Back to the menu $1 s after the script ends: the menu core reloaded through MiSTer's command pipe, as leaving a core does.
# Only from the menu, never while a core runs (the name is read again just before)
back_to_menu() {
  if [ "$(cat /tmp/CORENAME 2> /dev/null)" = "MENU" ] && [ -p /dev/MiSTer_cmd ]; then
    echo "Back to the menu in a moment."
    setsid sh -c "sleep $1; [ \"\$(cat /tmp/CORENAME 2> /dev/null)\" = MENU ] && echo 'load_core menu.rbf' > /dev/MiSTer_cmd" \
      > /dev/null 2>&1 < /dev/null &
  fi
}

if [ ! -f "$S" ]; then
  echo "$S not found: copy the release's m2mpegd folder to the SD card's root."
  back_to_menu 10
  exit 1
fi

if [ -f "$U" ] && grep -q "m2mpegd_service.sh" "$U"; then
  echo "Auto-start was already on."
else
  [ -f "$U" ] || printf '#!/bin/sh\n' > "$U"
  cp "$U" "$U.bak_m2mpegd"
  [ -n "$(tail -c 1 "$U")" ] && echo >> "$U"   # (the file's last line ended, so ours stays a line of its own)
  printf '# Battle Tryst MPEG daemon (m2mpegd_autostart_on.sh adds this line, m2mpegd_autostart_off.sh removes it)\n%s\n' \
    "$LINE" >> "$U"
fi

if $S start; then
  echo "Battle Tryst movies: ON"
  back_to_menu 3
else
  echo "Battle Tryst movies: auto-start on, but the decoder didn't start (above)."
  back_to_menu 10
fi
