# ROM server behaviour, as recorded

This file contains a description of what the Portfolio's built-in server (Setup → File transfer → Server) actually
does, from the transcripts in `tests/golden/rom/` (recorded 2026-11-14 on an
HPC-004 with pofoprobe). This is the reference for PortfolioServer: where this
file and [protocol.md](protocol.md) disagree, this file wins.

Test files are those made by MKFIX (see `tests/README.md`).

## General

- **One command buffer, never cleared.** A request only overwrites the bytes
  it carries. A 1-byte `06` block lists the pattern from the previous list
  request; error replies carry stale bytes (see `02`).
- **Commands are limited in length.** 82 and 90-byte blocks and a 13-byte
  one are fine; a 120-byte command block makes the ROM stop after the length
  bytes and show "Communications Error", leaving server mode (case 51). The
  exact limit isn't known yet (somewhere from 90 to 119).
- **Wrong-length blocks mid-command end server mode.** Where the ROM expects
  the 3-byte finish block, an 82-byte block gives "Communications Error"
  (case 52); so does a data block longer than the block size (case 47).
- **Unknown codes are acknowledged and ignored**: `01`, `07`, `20`, `21`,
  `40`, `FF`, and `05` / `00` outside a send. The block's checksum is echoed,
  no reply follows, and the ROM goes straight back to idle (`5A`).
- **`04` leaves server mode**: block acknowledged, no reply, no more `5A`; the
  Portfolio goes back to the File transfer menu (case 50).
- **Idle:** "receive block" in a loop, so the client sees `5A` repeatedly.
- **Drive B:** never use it. B: is a phantom of the card slot: DOS stops and
  asks "Insert disk for drive B:" on the Portfolio, and the next use of A:
  then asks for A:. The server stalls until a key is pressed.

## Buffer size field (bytes 1-2 of every request)

**Not ignored.** The ROM keeps a block size, 0x7000 when server mode starts,
and every `06`, `02` and `03` request lowers it to the request's field if
that is smaller. It never goes back up until server mode is restarted
(cases 45, 46, 47).

- Replies report the current size: `02` header bytes 1-2, `03` reply bytes
  1-2. (`06` replies have no size field.)
- `02` data goes in blocks of the current size.
- `03` data blocks larger than the current size end server mode.

rpfolio always sends `00 70`, so it never sees this.

## `06` list

Reply: count (u16), then the names, each NUL-terminated (`tests/golden/rom/10-list.txt`).

- DOS FindFirst/FindNext with **attribute 0**: plain files, read-only files
  and files without the archive bit are listed; **hidden and system files are
  not, even by exact name**; folders are not, with or without a trailing
  `\`.
- Names are as DOS stores them (upper case); a lower-case pattern works.
- `NUL` matches in **every existing folder, including the root** (`C:\NUL`,
  `C:\PT\NUL`, `C:\PT\SUB\NUL`, `A:\PT\NUL` all return `01 00 "NUL" 00`),
  and not in a missing one (`C:\NOPE\NUL` → `00 00`). PiPortfolioDaemon's
  folder check relies on this.
- No match, missing folder, drive D:, an empty pattern, `C:` alone, a
  wildcard in a folder part (`C:\P*\*.*`) and a 79-character pattern with no
  NUL all return `00 00`.
- No drive letter uses the current drive and folder, which was `C:\` (`*.*`
  listed `C:\`, `\PT\*.*` listed `C:\PT`).
- `?` and `*.` work as in DOS.

## `02` receive

Header (11 bytes): status, block size (u16), time (u16), date (u16), size
(u32) (`20-receive.txt`).

- Found: status `20`, then the file's own time, date and size, then the data
  in blocks of the block size (none for a zero-length file: the client sends
  the finish block straight after the header). A 28,672-byte file is one
  block; 28,673 bytes are one block plus a 1-byte block.
- Found by FindFirst with attribute 0, so **hidden and system files count as
  missing**. Read-only and no-archive files are sent normally.
- **Missing file, hidden or system file, or a folder: status `21`.** No data
  follows; the ROM goes back to idle without waiting for a finish block.
- **A wildcard in the name (`S*.TXT`): status `10`**, no data, back to idle.
- **On `21` and `10`, bytes 3-10 are stale**: the time, date and size from
  the previous successful header, untouched. (Bytes 1-2 hold the current
  block size.)
- After the last data block the ROM waits for the finish block `20 00 03`.

## `03` send

Request: header with time, date and size; reply (3 bytes): status, block
size (u16) (`30-send.txt`).

- New file: `21`. Existing file: `20`. The existence check is FindFirst with
  attribute 0, so an existing **hidden or system file gets `21`**, as new.
- A name with a wildcard (`A*B.TXT`): `10`, and the ROM goes back to idle.
- A folder name, a missing folder: still `21`; the failure only shows at the
  end.
- After `20` the client sends `05 00 70` (overwrite) or `00 00 00` (cancel:
  the file is untouched and the ROM goes back to idle).
- Then the data, in blocks of at most the block size; none for a zero-length
  file (the final reply follows the `21` directly).
- **Final reply: `20 D7 39` on success, `10 D7 39` on failure** (read-only
  file, folder name, missing folder, disk full). `D7 39` is the HPC-004
  value; the HPC-006 sends `D8 39`.
- **When the file can't be created** (read-only, folder name, missing folder,
  or an existing hidden or system file behind a `21`), the ROM fails after
  the **first** data block: it replies `10 D7 39` at once, without waiting
  for the rest.
- **When a write fails** (disk full, 40,000 bytes to C:), it takes **every**
  remaining data block, then replies `10 D7 39` (case 40).
- **On any failure it deletes the target by name** (`41h`): the partial file
  after a disk full, and even an existing hidden file it never wrote to
  (`C:\PT\HID.TXT` was gone after the hidden-file case; found with the trace
  in case 35). Read-only files survive because DOS won't delete them.
- **The ROM keeps trying to send a reply** while the client isn't listening:
  its early `10 D7 39` waited over 3 s for a client that was still trying to
  send its next block.
- The file gets the **time and date from the request** (rpfolio always sends
  `0C 7A 21 32`: 15:16:24, 2005-01-01).
- Overwriting truncates to the new size. Names longer than 8.3 are cut by
  DOS (`LONGFILENAME.TEXT` → `LONGFILE.TEX`); lower-case names are stored in
  upper case.

### ROM bug: an upload of exactly one full block

Uploading a file of exactly 28,672 bytes (one full 0x7000 block) fails on
the ROM, three times out of three (`tests/golden/rom/roundtrip.txt`): rpfolio
sends the whole block, the ROM echoes its checksum, and then never sends the
final `20 D7 39`. After a while it shows "Communications Error" and leaves
server mode; rpfolio reports "Acknowledge ERROR (received 5A instead of
A5)". The file is not left behind. Probably the ROM waits for another data
block after a block that ends the file exactly; sizes that are other
multiples of 0x7000 haven't been tried. 28,671 and 28,673 bytes work, and
downloads of 28,672 bytes work. PortfolioServer does not copy this bug.

## DIP DOS notes

- FindFirst with attribute `16h` finds hidden and system files and folders
  (PortfolioServer's `41`). An earlier note here said attribute `06h` didn't
  find hidden files; that was wrong: the test failed for another reason
  (PortfolioServer gave up on a reply too early, since fixed).
- Create (`3Ch`) on an existing hidden file succeeds and truncates it, so
  "is there a hidden file?" has to be checked before creating.

## Still open

- The exact command length limit (between 90 and 119 bytes).
- What limits a `06` reply: the block size, the request's size field, or
  nothing (all recorded listings were small).
- What the ROM does with a 3-byte block other than `20 00 03` where it
  expects the finish block, and how long it waits for one.
