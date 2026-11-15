#!/bin/bash
# The patched rpfolio against the ROM's built-in server, run ON THE PI.
#
#   ssh "$PI" bash -s < tests/rom-fallback.sh > log.txt
#
# RPFOLIO names the patched rpfolio if it isn't the one on the PATH.
#
# Every PortfolioServer option (-i, -x, -q, -e, -m, -k, -s) must say the
# built-in server is running and exit with code 3, without hanging; the
# ROM must not have acted on the command; and the ROM must still serve the
# ordinary commands (-l, -r, -t) through the same patched rpfolio after
# each one. Run after MKFIX, with the ROM server running. The log has no
# timings, so runs can be diffed (reference: tests/golden/rom/fallback.txt).

set -u
RPFOLIO=${RPFOLIO:-rpfolio}
work=/tmp/pofo-fallback
rm -rf "$work"; mkdir -p "$work"
problems=0

# Run the patched rpfolio, print its output without byte counters, then its
# exit code. A minute is plenty: a hang means a failed test.
run() {
	echo "\$ rpfolio $*"
	timeout 60 "$RPFOLIO" "$@" 2>&1 | tr '\r' '\n' \
		| grep -v -e '^Sent [0-9]* of' -e '^Received [0-9]* of' \
		          -e '^Waiting for Portfolio' -e '^ *$'
	last=${PIPESTATUS[0]}
	echo "exit $last"
}

expect() {      # exit code wanted, description
	if [ "$last" != "$1" ]; then
		echo "PROBLEM: $2: exit $last, expected $1"
		((problems++))
	fi
}

# The ROM still answers an ordinary listing after each new command.
still_serving() {
	run -l 'C:\PT\*.TXT'
	expect 0 "ROM still serving"
}

echo "## -i (info)"
run -i;                       expect 3 "-i"
still_serving

echo; echo "## -x (long listing)"
run -x 'C:\PT\*.*';           expect 3 "-x"
still_serving

echo; echo "## -s (free space), two drives"
run -s C: A:;                 expect 3 "-s"
still_serving

echo; echo "## -e (delete): the ROM must not delete SMALL.TXT"
run -e 'C:\PT\SMALL.TXT';     expect 3 "-e"
run -l 'C:\PT\SMALL.TXT';     expect 0 "SMALL.TXT listing"
grep -q '^SMALL.TXT' <<<"$(timeout 60 "$RPFOLIO" -l 'C:\PT\SMALL.TXT' 2>/dev/null)" \
	|| { echo "PROBLEM: SMALL.TXT is gone"; ((problems++)); }

echo; echo "## -e with several paths: stops at the first"
run -e 'C:\PT\SMALL.TXT' 'C:\PT\NOEXT';  expect 3 "-e, two paths"
still_serving

echo; echo "## -m (make folder): the ROM must not make NEWDIR"
run -m 'C:\PT\NEWDIR';        expect 3 "-m"
run -l 'C:\PT\NEWDIR\NUL';    expect 0 "NEWDIR check"     # "No files." = no folder

echo; echo "## -k (remove folder): the ROM must not remove SUB"
run -k 'C:\PT\SUB';           expect 3 "-k"
run -l 'C:\PT\SUB\NUL';       expect 0 "SUB check"        # "NUL" = folder still there

echo; echo "## -q (quit): the ROM must keep serving"
run -q;                       expect 3 "-q"
still_serving

echo; echo "## ordinary transfers through the patched rpfolio"
head -c 3000 /dev/urandom >"$work/up"
run -f -t "$work/up" 'C:\PT\FALLBACK.BIN';  expect 0 "-t"
run -f -r 'C:\PT\FALLBACK.BIN' "$work/down"; expect 0 "-r"
if cmp -s "$work/up" "$work/down"; then
	echo "compare: identical"
else
	echo "PROBLEM: FALLBACK.BIN came back different"; ((problems++))
fi

echo
echo "fallback: $problems problem(s)"
