#!/bin/bash
# rpfolio round trips, run ON THE PI against whichever server is running.
#
#   tests/roundtrip.sh > log.txt
#
# Uploads files of sizes around the block size with an unmodified rpfolio,
# downloads them again and compares them with the originals, then tries the
# overwrite, wildcard and several-file cases. The upload of exactly 28,672
# bytes comes last: the ROM fails it (see the end of this script).
#
# Prints a log with rpfolio's messages (byte counters dropped) and exit
# codes, so the ROM's and
# PortfolioServer's logs can be diffed. Run after MKFIX: it writes only in C:\PT
# and A:\PT, which MKFIX rebuilds.
#
# From another computer:  ssh "$PI" bash -s < tests/roundtrip.sh > log.txt

set -u
RPFOLIO=${RPFOLIO:-rpfolio}
work=/tmp/pofo-roundtrip
rm -rf "$work"
mkdir -p "$work/src" "$work/back" "$work/dir"

# Test files: the same pseudo-random bytes every run.
python3 -I - "$work/src" <<'EOF'
import random, sys
for size in (0, 1, 100, 10000, 20000, 28671, 28672, 28673, 40000, 57345):
    r = random.Random(size)
    with open(f"{sys.argv[1]}/s{size}", "wb") as f:
        f.write(bytes(r.randrange(256) for _ in range(size)))
EOF

# Run rpfolio, print its output without byte counters, then its exit code.
run() {
	echo "\$ rpfolio $*"
	# rpfolio waits for ever if the server is gone: give up after 2 minutes
	timeout 120 "$RPFOLIO" "$@" 2>&1 | tr '\r' '\n' \
		| grep -v -e '^Sent [0-9]* of' -e '^Received [0-9]* of' \
		          -e '^Waiting for Portfolio' -e '^ *$' \
		| sed 's/^Waiting for Portfolio\.\.\. *//'
	echo "exit ${PIPESTATUS[0]}"
}

roundtrip() {   # drive size
	local drive=$1 size=$2 dest="$1:\\PT\\RT.BIN"
	echo
	echo "## $size bytes via $dest"
	run -f -t "$work/src/s$size" "$dest"
	rm -f "$work/back/rt"
	run -f -r "$dest" "$work/back/rt"
	if cmp -s "$work/src/s$size" "$work/back/rt"; then
		echo "compare: identical"
	else
		echo "compare: DIFFERENT ($(stat -c %s "$work/back/rt" 2>/dev/null || echo none) bytes back)"
	fi
}

for size in 0 1 100 10000 20000; do roundtrip C "$size"; done
for size in 28671 28673 40000 57345; do roundtrip A "$size"; done

echo
echo "## upload over an existing file without -f"
run -t "$work/src/s100" 'C:\PT\RT.BIN'

echo
echo "## download over an existing local file without -f"
touch "$work/back/exists"
run -r 'C:\PT\SMALL.TXT' "$work/back/exists"

echo
echo "## download with a wildcard into a folder"
run -r 'A:\PT\*.BIN' "$work/dir"
for f in B28672.BIN B28673.BIN RT.BIN; do
	printf '%s: ' "$f"; stat -c %s "$work/dir/$f" 2>/dev/null || echo missing
done

echo
echo "## upload several files into a folder"
cp "$work/src/s1" "$work/src/one.bin"
cp "$work/src/s100" "$work/src/hundred.bin"
run -f -t "$work/src/one.bin" "$work/src/hundred.bin" 'C:\PT\'
run -l 'C:\PT\*.BIN'

echo
echo "## download of a missing file"
run -r 'C:\PT\NOPE.TXT' "$work/back/nope"

echo
echo "## folder check, as PiPortfolioDaemon does it"
run -l 'C:\PT\NUL'
run -l 'C:\NOPE\NUL'

# Last, because the ROM fails it and leaves server mode ("Communications
# Error", seen twice 2026-11-14): an upload of exactly one full block.
# PortfolioServer passes it.
roundtrip A 28672
