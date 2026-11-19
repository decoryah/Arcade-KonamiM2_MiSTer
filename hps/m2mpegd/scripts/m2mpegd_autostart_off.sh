#!/bin/sh
# m2mpegd_autostart_off.sh (in /media/fat/Scripts): Battle Tryst's movies off. Removes the line m2mpegd_autostart_on.sh added
# to /media/fat/linux/user-startup.sh and stops the MPEG daemon; the game then plays with black movies. Run again, it changes
# nothing. It goes back to the menu by itself, as m2mpegd_autostart_on.sh does.
U=/media/fat/linux/user-startup.sh
S=/media/fat/m2mpegd/m2mpegd_service.sh

# Back to the menu $1 s after the script ends: the menu core reloaded through MiSTer's command pipe, as leaving a core does.
# Only from the menu, never while a core runs (the name is read again just before)
back_to_menu() {
  if [ "$(cat /tmp/CORENAME 2> /dev/null)" = "MENU" ] && [ -p /dev/MiSTer_cmd ]; then
    echo "Back to the menu in a moment."
    setsid sh -c "sleep $1; [ \"\$(cat /tmp/CORENAME 2> /dev/null)\" = MENU ] && echo 'load_core menu.rbf' > /dev/MiSTer_cmd" \
      > /dev/null 2>&1 < /dev/null &
  fi
}

# (also the line and comment an earlier m2mpegd_autostart.sh added)
if [ -f "$U" ] && grep -q -e "m2mpegd_service.sh" -e "m2mpegd_autostart" "$U"; then
  cp "$U" "$U.bak_m2mpegd"
  grep -v -e "m2mpegd_service.sh" -e "m2mpegd_autostart" "$U.bak_m2mpegd" > "$U"
else
  echo "Auto-start was already off."
fi

if [ -f "$S" ]; then
  $S stop
elif pidof m2mpegd > /dev/null 2>&1; then
  killall -TERM m2mpegd
fi
echo "Battle Tryst movies: OFF"
back_to_menu 3
