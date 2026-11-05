#!/bin/bash
# run_all.sh: every bench, from WSL (wsl -e bash /mnt/c/repos/konamim2-mister/mister/sim/run_all.sh). Captures and MAME's
# sources are in ../work (tools/lua/m2_capture.lua, tools/lua/ppc_trace.lua). Prints one line per bench; exit status 0
# when all pass. A bench whose capture isn't in ../work is skipped.
S=/mnt/c/repos/konamim2-mister/mister/sim
W=/mnt/c/repos/konamim2-mister/work
fail=0
check() { if echo "$2" | grep -q "$3"; then echo "PASS  $1: $(echo "$2" | tail -1)"; else echo "FAIL  $1"; echo "$2" | tail -5; fail=1; fi; }
have() { if [ -f "$2" ]; then return 0; fi; echo "SKIP  $1: no $2"; return 1; }

out=$(sh $S/lint.sh 2>&1);                                               check "lint" "$(echo "$out"; echo "lint done, $(echo "$out" | grep -c '^%') messages")" "lint done, 0 messages"
check "dspp"    "$(bash $S/dspp/run.sh 300 3000 2>&1)"                     "^PASS"
check "cdda"    "$(bash $S/dspp/run_cdda.sh 2>&1)"                         "^PASS"
check "ppcfpu"  "$(bash $S/ppcfpu/run.sh 2000000 2>&1)"                    "^PASS"
check "ppcfpu fpp" "$(FPP=1 bash $S/ppcfpu/run.sh 2000000 2>&1)"             "^PASS"
check "ppccore" "$(bash $S/ppccore/run.sh 5000 2>&1)"                      "^PASS"
check "ppccore pipe"         "$(PIPE=1 bash $S/ppccore/run.sh 5000 200 1 0 2>&1)"  "^PASS"
check "ppccore pipe latency" "$(PIPE=1 bash $S/ppccore/run.sh 3000 200 2 1 2>&1)"  "^PASS"
check "ppccore cache"         "$(PIPE=1 CACHE=1 bash $S/ppccore/run.sh 5000 200 1 0 2>&1)"  "^PASS"
check "ppccore cache latency" "$(PIPE=1 CACHE=1 bash $S/ppccore/run.sh 3000 200 2 1 2>&1)"  "^PASS"
# the MAME traces: the reference model against MAME, the RTL core against the model
T=$W/cap
if have "ppcreplay boot" $T/boot/p1.tr; then
	check "ppcreplay boot"      "$(bash $S/ppcreplay/run.sh $T/boot/p1.tr -quiet 2>&1)"                      " 0 errors;"
	check "ppcreplay boot RTL"  "$(RTL=1 bash $S/ppcreplay/run.sh $T/boot/p1.tr -quiet 2>&1)"                " 0 errors;"
	check "ppcreplay boot pipe" "$(RTL=1 PIPE=1 bash $S/ppcreplay/run.sh $T/boot/p1.tr -quiet 2>&1)"         " 0 errors;"
fi
for c in ppc1 ppc2; do
	if have "ppcreplay t900 $c" $T/t900/$c.tr; then
		check "ppcreplay t900 $c RTL" "$(NOBUILD=1 RTL=1 bash $S/ppcreplay/run.sh $T/t900/$c.tr -ram $T/t900/ram.bin \
			-state $T/t900/$c.state -quiet 2>&1)" " 0 errors;"
		check "ppcreplay t900 $c pipe" "$(NOBUILD=1 RTL=1 PIPE=1 bash $S/ppcreplay/run.sh $T/t900/$c.tr -ram $T/t900/ram.bin \
			-state $T/t900/$c.state -quiet 2>&1)" " 0 errors;"
	fi
done
check "coh" "$(bash $S/coh/run.sh 4000000 1 2>&1)" "^PASS"
check "coh latency" "$(bash $S/coh/run.sh 4000000 2 2>&1)" "^PASS"
if have "m2boot" $T/boot/p1.tr; then
	check "m2boot" "$(bash $S/m2boot/run.sh 2>&1)" "^PASS"
fi
exit $fail
