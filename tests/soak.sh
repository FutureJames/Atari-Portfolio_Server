#!/bin/bash
# Soak test, run ON THE PI against PortfolioServer (not the ROM: killed clients
# leave the ROM stuck until server mode is restarted by hand).
#
#   ssh "$PI" bash -s -- CYCLES < tests/soak.sh
#
# Each cycle uploads a 1,000-byte file of new random bytes to C:\PT\SOAK.BIN,
# downloads it, compares it and lists C:\PT. Every 25 cycles it kills an
# upload and then a download part-way, and checks that the next command
# still works once PortfolioServer has given up on the dead client (10 s).
# Prints one line per problem and a summary. Run after MKFIX.

set -u
cycles=${1:-200}
work=/tmp/pofo-soak
rm -rf "$work"; mkdir -p "$work"
fails=0
retried=0   # killed downloads where the next command needed a second try
t0=$(date +%s)

q() { timeout 120 rpfolio "$@" >"$work/out" 2>&1; }

for ((i = 1; i <= cycles; i++)); do
	head -c 1000 /dev/urandom >"$work/up"
	if ! q -f -t "$work/up" 'C:\PT\SOAK.BIN'; then
		echo "cycle $i: upload failed: $(tr '\r' '\n' <"$work/out" | tail -2 | tr '\n' ' ')"
		((fails++)); continue
	fi
	rm -f "$work/down"
	if ! q -f -r 'C:\PT\SOAK.BIN' "$work/down"; then
		echo "cycle $i: download failed: $(tr '\r' '\n' <"$work/out" | tail -2 | tr '\n' ' ')"
		((fails++)); continue
	fi
	if ! cmp -s "$work/up" "$work/down"; then
		echo "cycle $i: DIFFERENT after the round trip"
		((fails++))
	fi
	if ! q -l 'C:\PT\*.*' || ! grep -q '^SOAK.BIN' "$work/out"; then
		echo "cycle $i: list failed"
		((fails++))
	fi

	if ((i % 25 == 0)); then
		# Kill an upload part-way (20,000 bytes take ~12 s).
		head -c 20000 /dev/urandom >"$work/big"
		rpfolio -f -t "$work/big" 'C:\PT\KILLED.BIN' >/dev/null 2>&1 &
		sleep 4; kill $! 2>/dev/null; wait $! 2>/dev/null
		if ! q -l 'C:\PT\*.*'; then
			echo "cycle $i: no answer after a killed upload"; ((fails++))
		elif grep -q '^KILLED.BIN' "$work/out"; then
			echo "cycle $i: killed upload left C:\\PT\\KILLED.BIN behind"; ((fails++))
		fi
		# Kill a download part-way.
		rpfolio -f -r 'A:\PT\B28673.BIN' "$work/b" >/dev/null 2>&1 &
		sleep 6; kill $! 2>/dev/null; wait $! 2>/dev/null
		# The next command may fail once: the killed client's block is still
		# being sent, and the new rpfolio's start-up handshake takes it in
		# until it meets a 5A byte. It must work on the second try.
		if ! q -l 'C:\PT\*.*'; then
			((retried++))
			if ! q -l 'C:\PT\*.*'; then
				echo "cycle $i: no answer after a killed download"; ((fails++))
			fi
		fi
		echo "cycle $i: $fails problem(s) so far, $(( $(date +%s) - t0 )) s"
	fi
done

echo "soak: $cycles cycles, $fails problem(s), $retried second tries after a killed download, $(( $(date +%s) - t0 )) s"
