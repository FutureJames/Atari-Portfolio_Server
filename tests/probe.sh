#!/bin/sh
# Run pofoprobe test cases on the Pi and collect the transcripts.
#
#   tests/probe.sh rom [CASE...]       record the ROM server -> tests/golden/rom/
#   tests/probe.sh portfolioserver [CASE...]   run against PortfolioServer -> tests/results/portfolioserver/,
#                                      then diff against tests/golden/rom/ (or, for
#                                      PortfolioServer's own commands, tests/golden/portfolioserver/)
#   tests/probe.sh record-portfolioserver CASE record PortfolioServer's own commands
#                                      -> tests/golden/portfolioserver/
#
# CASE is a file name in tests/cases (e.g. 10-list.txt); default: all of them.
# Needs ~/pofoprobe on the Pi (tools/pofoprobe) and SSH to the Pi, given as
# PI, e.g.  PI=pi@raspberrypi.local tests/probe.sh portfolioserver

set -eu
PI=${PI:?set PI to the Pi's SSH address, e.g. PI=pi@raspberrypi.local}
here=$(cd "$(dirname "$0")" && pwd)
label=${1:?usage: probe.sh LABEL [CASE...]}
shift

if [ "$label" = rom ]; then
	out=$here/golden/rom
elif [ "$label" = record-portfolioserver ]; then
	out=$here/golden/portfolioserver
else
	out=$here/results/$label
fi
mkdir -p "$out"

if [ $# -eq 0 ]; then
	set -- $(cd "$here/cases" && ls *.txt)
fi

for case in "$@"; do
	printf '%s ... ' "$case"
	# Each case may take a while: big blocks run at ~1.7 KB/s.
	if ssh "$PI" 'timeout 600 ~/pofoprobe -' <"$here/cases/$case" >"$out/$case"; then
		echo ok
	else
		echo "done, with failed steps (see $out/$case)"
	fi
done

if [ "$label" != rom ] && [ "$label" != record-portfolioserver ]; then
	for case in "$@"; do
		golden=$here/golden/rom/$case
		[ -f "$golden" ] || golden=$here/golden/portfolioserver/$case
		# "= sync" lines say how many stray bytes came first: timing, not protocol
		if diff -u -I '^= sync' "$golden" "$out/$case" >"$out/$case.diff"; then
			rm -f "$out/$case.diff"
			echo "$case: same as $(basename "$(dirname "$golden")")"
		else
			echo "$case: DIFFERENT, see $out/$case.diff"
		fi
	done
fi
