# PortfolioServer protocol

PortfolioServer is a DOS `.COM` program for the Atari Portfolio that replaces the
ROM's built-in file transfer server (Setup → File transfer → Server). It
speaks the same wire protocol, so an unmodified transfolio / `rpfolio` keeps
working, and it adds commands the ROM server lacks. It should also work with
a PC running `FT.COM`, the DOS program "Atari Portfolio File Transfer" that
shipped with the Portfolio (not tested yet).

## Sources

- Klaus Peichl's description of the ROM server protocol (German):
  <https://www.pofowiki.de/doku.php?id=software:vorstellung:exchanges:transfolio>
- `transfolio.c` (github.com/skudi/transfolio, commit `ab89073`), the client
  side.
- *Portfolio Technical Reference Guide*, 1st edition, Sep 1989, section 3.3.1
  (Int 61h function 30h) and section 4.2 (Smart Parallel Interface)
  ([on archive.org](https://archive.org/details/Protfolio_Technical_Reference_Guide_1st_Edition_Sep_1989)).

## Layers

### Bit level

Handled entirely by the BIOS. Bytes go bit-serially, MSB first, on one data
line and one clock line in each direction, using both clock edges. PortfolioServer
never touches the port directly.

### Block level: Int 61h function 30h

| AX     | Meaning        | Inputs                                   | Returns |
|--------|----------------|------------------------------------------|---------|
| `3000` | Transmit block | DS:DX buffer, CX bytes to send           | DL error |
| `3001` | Receive block  | DS:DX buffer, CX buffer size             | CX bytes received, DL error |
| `3002` | Open ports     |                                          | DL error |
| `3003` | Close ports    |                                          | DL error |
| `3004` | Wait 500 ms    |                                          |         |

Error codes in DL: 0 none, 1 buffer too small, 2 timeout, 3 checksum failure,
4 invalid sub-service, 5 peripheral not installed. Not in the TRG: the real
machine returns **6** from "receive block" about every 500 ms while no client
is answering (seen 2026-11-14), so PortfolioServer treats 6 like 2.

The TRG's rules: open the ports before transferring and close them at the
end; a send must meet a receive at the other end; there is a 500 ms timeout;
after any failure wait 500 ms (so the other end times out too) and retry.

On the wire a block is:

| Sender            | Receiver | Meaning |
|-------------------|----------|---------|
|                   | `5A`     | ready to receive |
| `A5`              |          | start of block |
| len lo, len hi    |          | 16-bit little-endian length |
| data …            |          | `len` bytes |
| checksum          |          | two's complement of the 8-bit sum of the length and data bytes |
|                   | checksum | echoed back as acknowledgement |

An idle server sits in "receive block", which sends `5A` and times out after
500 ms; looping on that is what makes the ROM server send `5A` repeatedly.
PortfolioServer does the same, checking the keyboard between attempts.

### Command level

Every command and reply is one block. The client (PC / Pi) always starts. All
multi-byte numbers are little-endian. Paths are ASCIIZ, at most 79
characters; anything after the NUL is padding.

Requests carry a buffer size at offsets 1–2; transfolio always sends `00 70`
(0x7000 = 28,672). The ROM does **not** ignore it: it keeps a block size,
0x7000 at start, and lowers it to any smaller value a request carries, until
server mode restarts. PortfolioServer does the same.

The exact ROM behaviour, including every error case, is in
[rom-behaviour.md](rom-behaviour.md). The summaries below follow it.

## ROM-compatible commands

These must behave exactly like the ROM so unmodified transfolio works.

### `06` List files

Request, 82 bytes: `06`, `00 70`, pattern (ASCIIZ), padding.

Reply: count (u16), then `count` NUL-terminated names (no path). Only plain
files are listed: DOS FindFirst/FindNext with attribute 0, so no folders,
hidden or system files. The ROM's wildcards only work in the last path part;
so do DOS's. `NUL` is found in every existing folder.

The reply must fit in the client's receive buffer. transfolio uses 60,000
bytes for `-l` but only 2,000 for the name check in `-r`.

### `02` Receive file (Portfolio → client)

Request, 82 bytes: `02`, `00 70`, path.

Reply, 11 bytes: `20`, block size, time (u16, DOS format), date (u16, DOS
format), size (u32). Then the file follows in data blocks of the block size.
The client ends with the finish block `20 00 03`.

Errors: `21` for a missing, hidden or system file or a folder; `10` for a
wildcard. Bytes 3–10 then still hold the previous successful header. No data
follows and there is no finish block.

### `03` Send file (client → Portfolio)

Request, 90 bytes: `03`, `00 70`, time (u16), date (u16), size (u32), path
(ASCIIZ at offset 11).

Reply, 3 bytes: status, block size. Status `21` = new (also for an
existing hidden or system file, a folder name or a missing folder), `20` =
exists, `10` = wildcard in the name (transfolio prints "Invalid destination
file!"; the command ends there).

If the file exists the client sends `05 00 70` (overwrite) or `00 00 00`
(cancel; the command ends there). Then the client sends the data in blocks of
at most the block size (none for a zero-length file), and the server ends
with `20 D7 39` on success or `10 D7 39` on failure (read-only file, bad
path, disk full; a partial file is removed). `D7 39` is the HPC-004 value,
`D8 39` the HPC-006 one; PortfolioServer always sends `D7 39` for now. The file
gets the time and date from the request.

### `05` Overwrite, `00` Cancel

Only valid as the answer to a `03` reply of `20`. Outside that they are
ignored, as by the ROM.

### `04`

Undocumented; makes the ROM server leave server mode: the block is
acknowledged, no reply follows. PortfolioServer treats it as `4F` Quit without the
reply, so a client that uses it to end server mode still works.

## Where PortfolioServer differs from the ROM

All recorded cases give byte-identical transcripts (`tests/probe.sh
portfolioserver`), except where the ROM gives up and leaves server mode with
"Communications Error". PortfolioServer logs "Transfer error 01" and goes back
to waiting for commands instead:

- a command block longer than 90 bytes (case 51);
- a data block longer than the block size (case 47);
- a block longer than 16 bytes where the finish block belongs (case 52).

Also deliberately different:

- an upload of exactly 28,672 bytes works; on the ROM it fails with
  "Communications Error" (a ROM bug, see rom-behaviour.md);
- if the client stops answering mid-command, PortfolioServer gives up after
  10 s (20 tries of 500 ms) and goes back to idle; the ROM needs server mode
  restarting by hand;
- if a client dies mid-upload and a new one connects, the new client's
  first command arrives where a data block was expected. A real client
  always sends blocks of exactly min(block size, bytes left), so a block of
  any other size is taken as the new client's command: the upload is
  dropped and the command answered ("New client: upload dropped");
- download data blocks are sent once, not retried (replies still are): a
  live client takes the next block at once.

Known limitation (protocol, not fixable in the server): if a client is
killed mid-download, the block being sent is not interrupted, and a new
rpfolio's start-up handshake acknowledges it bit by bit until it meets a
`5A` byte in the data. Its first command then fails; the second works
(soak test: 6 of 8 killed downloads). PiPortfolioDaemon only kills rpfolio
when a transfer has already stalled, when this doesn't arise.
- `04` ends PortfolioServer and returns to the DOS prompt (the ROM returns to
  the File transfer menu); on the wire both just acknowledge the block;
- the Portfolio doesn't switch itself off while PortfolioServer runs;
- the screen shows PortfolioServer's own log lines.

The final `03` reply is `20 D7 39` / `10 D7 39`, the HPC-004 values. On an
HPC-006 the ROM sends `D8 39`; PortfolioServer doesn't detect the model yet.

## New commands

New commands use `40`–`4F`, well clear of the ROM codes and the `20`/`21`
reply codes. Sent to the ROM server they get no reply (recorded: the block is
acknowledged and the ROM goes back to idle): the client sees a `5A` where it
expected `A5`, which is how a client can tell the ROM is running instead of
PortfolioServer.

All of `40`–`45` and `4F` are implemented (PortfolioServer 0.4).
The rpfolio side is `patches/rpfolio-portfolioserver.patch`:

| Option | Command | Output |
|--------|---------|--------|
| `-i` | `40` | `PortfolioServer 0.4, block size 28672 bytes.` |
| `-x PATTERN` | `41` | one line per entry: `----a      100 2000-01-01 12:00:00 SMALL.TXT` (attributes `d` folder, `r` read-only, `h` hidden, `s` system, `a` archive) |
| `-q` | `4F` | `PortfolioServer stopped.` |
| `-e PATH...` | `42` | `Deleted C:\PT\SMALL.TXT` |
| `-m PATH...` | `43` | `Made folder C:\PT\NEWDIR` |
| `-k PATH...` | `44` | `Removed folder C:\PT\NEWDIR` |
| `-s DRIVE...` | `45` | `A: 66560 bytes free of 125952` |

`-e`, `-m`, `-k` and `-s` take several paths, print a line for each, and
exit with code 1 if any failed, e.g. `Cannot delete C:\PT\RO.TXT: access
denied (read-only, not empty, or exists) (DOS error 5)`.

With the ROM's server running, every one of these options prints "No
reply: the Portfolio is running its built-in server, not PortfolioServer."
and exits with code 3, and the ROM acts on none of them and keeps serving
(`tests/rom-fallback.sh`, log in `tests/golden/rom/fallback.txt`). So one
patched rpfolio works with both servers: `-l`, `-r` and `-t` work with
either, and a caller can try a PortfolioServer option and fall back on
exit code 3.

### `40` Info

Request: `40` (any length; transfolio-style `40 00 70` is fine).

Reply, 8 bytes:

| Offset | Size | Meaning |
|--------|------|---------|
| 0 | 1 | `20` OK |
| 1 | 2 | buffer size, `00 70` |
| 3 | 2 | signature `'P' 'S'` |
| 5 | 1 | version major |
| 6 | 1 | version minor |
| 7 | 1 | reserved, 0 |

### `41` Directory listing

Request, 82 bytes: `41`, `00 70`, pattern (ASCIIZ), padding — the same as
`06`.

One DOS FindFirst/FindNext pass with attribute `16h` (files and folders;
hidden and system files are included too, with their attribute bits set, so
the client can show or hide them). `.` and `..` are left out. It doesn't
change the block size.

Reply: a 4-byte header, then `count` 22-byte records.

| Offset | Size | Meaning |
|--------|------|---------|
| 0 | 2 | count |
| 2 | 1 | flags: bit 0 = truncated (buffer full, more entries exist) |
| 3 | 1 | reserved, 0 |

Each record is the useful tail of the DOS DTA:

| Offset | Size | Meaning |
|--------|------|---------|
| 0 | 1 | attributes (`01` read-only, `02` hidden, `04` system, `10` folder, `20` archive) |
| 1 | 2 | time, DOS format (bits 15–11 hours, 10–5 minutes, 4–0 seconds/2) |
| 3 | 2 | date, DOS format (bits 15–9 year−1980, 8–5 month, 4–0 day) |
| 5 | 4 | size in bytes (0 for folders) |
| 9 | 13 | name, ASCIIZ, NUL-padded (e.g. `README.TXT`) |

0x7000 bytes hold 1,303 records, far more than fit on the Portfolio's drives.

### `42` Delete file, `43` Make folder, `44` Remove folder

Request, 82 bytes: code, `00 70`, path (ASCIIZ), padding.

DOS calls: Int 21h `41h`, `39h`, `3Ah`.

Reply, 3 bytes: `20 00 00` OK, or `10`, DOS error code (u16). Recorded
errors: `02` file not found (also for any wildcard, which is refused), `03`
path not found, `05` access denied (a read-only file, a folder that exists
or isn't empty), `0F` invalid drive. Hidden and system files can be
deleted.

**Drive B: is refused** (`10 0F 00`) in `42`–`45`: on the Portfolio B: is
a phantom of the card slot, and DOS would stop and ask on the Portfolio's
screen for a disk.

### `45` Free space

Request, 82 bytes: `45`, `00 70`, drive path such as `C:` or `A:\` (only
the letter is used; empty = current drive).

DOS call: Int 21h `36h`.

Reply, 11 bytes: status (`20`/`10`), free bytes (u32), total bytes (u32),
reserved (u16, 0). On failure (an invalid drive, or B:): `10`, the DOS error
(u16) in bytes 1-2, zeros after. Recorded: A: 66,560 of 125,952 bytes free
with the MKFIX files; C: (the 32 KB RAM disk) has 31,232 bytes in all.

### `4F` Quit

Request: `4F` (any length).

Reply, 3 bytes: `20 00 00`. The server then closes the ports and exits to
DOS.

## Server behaviour

- On start: print a banner, open the ports (exit with a message if DL=5, no
  parallel module), then loop on "receive block".
- Between receive attempts (each times out after 500 ms) check the keyboard
  with Int 16h function 01h; Esc quits.
- The Portfolio only powers itself down inside Int 16h function 00h (waiting
  for a key). PortfolioServer never calls that while serving, so the machine stays
  on while the server runs. That fixes the ROM server's habit of switching
  off mid-session, at the cost of battery. An idle timeout may come later.
- After a checksum error or a failed send, wait 500 ms (`3004`) and go back
  to waiting for a command, as the TRG recommends.
- The screen shows one short line per command (the Portfolio's screen is
  40×8).

## Memory

A `.COM` gets one 64 KB segment. PortfolioServer uses one 0x7000-byte transfer
buffer plus a small command buffer, DTA and stack, about 30 KB in all. It
checks the PSP's top-of-memory word at start and exits if there isn't
enough. It doesn't shrink its memory block, since it starts no other
programs.
