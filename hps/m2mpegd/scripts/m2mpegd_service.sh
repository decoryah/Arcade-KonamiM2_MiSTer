#!/bin/sh
# m2mpegd_service.sh start|stop|status: the MPEG daemon as a background service (on the MiSTer, in /media/fat/m2mpegd).
# - start: from the auto-start line in /media/fat/linux/user-startup.sh (m2mpegd_autostart.sh adds it), so the daemon waits
#   for Battle Tryst from boot on. It does nothing while another core runs: it reads /tmp/CORENAME once a second.
# - start once: the launcher's mode (Battle_Tryst_MPEG.sh): the daemon leaves by itself when Tryst goes, or if Tryst isn't
#   loaded within 60 seconds.
# - stop: the daemon leaves cleanly (SIGTERM: the core stops waiting for it at once).
# One copy at a time; its messages in /tmp/m2mpegd.log (RAM, not the SD card).
D=/media/fat/m2mpegd
BASE=30400000
LOG=/tmp/m2mpegd.log
# A picture is copied into the game's block 22 ms after its end entry: the game redraws the movie from
# the block every frame, so a copy at a fixed point after the picture's start keeps clear of that read (no tears on a MiSTerPi
# at 20, 22 and 24 ms; 22 had no picture miss its time). Two decode threads are the daemon's default.
PACE=22

running() { pidof m2mpegd > /dev/null 2>&1; }

case "$1" in
  start)
    if running; then
      echo "m2mpegd: already running"
      exit 0
    fi
    if [ "$2" = once ]; then MODE="--until-gone 60"; else MODE=""; fi
    [ -x "$D/m2mpegd" ] || { echo "m2mpegd: $D/m2mpegd not found"; exit 1; }
    # The write-combined module (kernel/m2_mem_wc: a picture's copy 0.3 ms instead of 3.7), one build per kernel named
    # m2_mem_wc-<uname -r>.ko (insmod refuses another kernel's anyway); without it the daemon writes game RAM through /dev/mem
    KO="$D/m2_mem_wc-$(uname -r).ko"
    if [ ! -e /dev/m2_mem_wc ]; then
      if [ -f "$KO" ]; then
        insmod "$KO" 2> /dev/null || echo "m2mpegd: $KO didn't load, game RAM through /dev/mem"
      else
        echo "m2mpegd: no m2_mem_wc for kernel $(uname -r), game RAM through /dev/mem"
      fi
    fi
    setsid nohup "$D/m2mpegd" --base $BASE --pace $PACE --log $LOG $MODE > /dev/null 2>&1 < /dev/null &
    sleep 1
    running && echo "m2mpegd: started" || { echo "m2mpegd: didn't start (see $LOG)"; exit 1; }
    ;;
  stop)
    if running; then
      killall -TERM m2mpegd
      i=0
      while running && [ $i -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
      running && killall -KILL m2mpegd
      echo "m2mpegd: stopped"
    fi
    ;;
  status)
    running && echo "m2mpegd: running (pid $(pidof m2mpegd))" || echo "m2mpegd: not running"
    ;;
  *)
    echo "usage: $0 start [once] | stop | status"
    exit 2
    ;;
esac
