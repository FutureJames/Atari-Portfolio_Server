# Compatibility tests

Recordings of exactly what the ROM server sends, and the means to check that
PortfolioServer sends the same. The ROM's behaviour they show is written up in
[../docs/rom-behaviour.md](../docs/rom-behaviour.md).

The tests run on a Raspberry Pi wired to the Portfolio's parallel port, as
for rpfolio. Set `PI` to the Pi's SSH address first, for example:

```sh
PI=pi@raspberrypi.local
```

`probe.sh` reads `PI` itself; the other scripts run on the Pi and are sent
there with `ssh "$PI" bash -s < tests/SCRIPT.sh`. Each one starts with a
comment saying what it checks and which server it needs.

| Path | What |
|------|------|
| `fixtures/mkfix.asm` | `MKFIX.COM`: rebuilds the test files on the Portfolio |
| `cases/*.txt` | [pofoprobe](../tools/pofoprobe/) scripts, one per area |
| `golden/rom/*.txt` | the ROM server's transcripts for those scripts |
| `results/LABEL/` | transcripts from other runs (not committed) |
| `probe.sh` | runs cases on the Pi and diffs against the ROM |
| `roundtrip.sh` | rpfolio uploads and downloads around the block size, compared byte for byte (`ssh "$PI" bash -s < tests/roundtrip.sh`) |
| `soak.sh` | 200 rpfolio cycles plus killed clients, PortfolioServer only (`ssh "$PI" bash -s -- 200 < tests/soak.sh`) |
| `rom-fallback.sh` | the patched rpfolio's PortfolioServer options against the ROM: each must exit with code 3 and leave the ROM untouched and serving (with the ROM server running: `ssh "$PI" bash -s < tests/rom-fallback.sh`) |
| `golden/rom/fallback.txt` | its log from the ROM (0 problems) |
| `golden/rom/roundtrip.txt` | the ROM's round-trip log (it fails the last step, see rom-behaviour.md) |

**Never use drive B: in a case.** On the Portfolio B: is a phantom of the
card slot: any access makes DOS stop and ask "Insert disk for drive B:" on
the Portfolio's screen, which stalls the server until someone presses a key.
Use D: for "bad drive" cases.

## Test files (MKFIX)

Every file's byte *i* is *i* mod 251. Time 12:00:00, date 2000-01-01.

| Path | Size | Attributes |
|------|------|-----------|
| `C:\PT\EMPTY.TXT` | 0 | archive |
| `C:\PT\SMALL.TXT` | 100 | archive |
| `C:\PT\RO.TXT` | 10 | read-only, archive |
| `C:\PT\HID.TXT` | 10 | hidden, archive |
| `C:\PT\SYS.TXT` | 10 | system, archive |
| `C:\PT\NOARC.TXT` | 10 | none |
| `C:\PT\NOEXT` | 10 | archive |
| `C:\PT\SUB\IN.TXT` | 20 | archive |
| `A:\PT\B28672.BIN` | 28,672 (one block) | archive |
| `A:\PT\B28673.BIN` | 28,673 (two blocks) | archive |
| `A:\PT\SUB\IN.TXT` | 20 | archive |

MKFIX first deletes `C:\PT`, `A:\PT` and (to make room on the card)
`A:\GAMES`, `A:\CARDTEST.TXT` and `A:\PIN.COM`. It ends by printing the
free space on A: and C:.

## Cases

| Case | Changes the Portfolio? | Covers |
|------|------------------------|--------|
| `10-list.txt` | no | `06`: patterns, attributes, folders, `NUL`, bad drives, odd requests |
| `20-receive.txt` | no | `02`: sizes around the block size, attributes, missing files, folders, wildcards |
| `30-send.txt` | yes | `03`/`05`/`00`: new, existing, cancel, read-only, bad paths, long names, two blocks |
| `35-send-trace.txt` | yes | `30-send.txt` with a listing after each case, to see which one changes the folder |
| `40-odd.txt` | yes, fills C: | unknown codes, `05`/`00` out of place, disk full, a 1-byte request |
| `45-bufsize.txt` | no | how a request's buffer size sets the block size (`06`) |
| `46-bufsize-02.txt` | no | the same for `02` |
| `47-bufsize-03.txt` | ends server mode | the same for `03` |
| `50-quit.txt` | ends server mode | `04` |
| `60-portfolioserver.txt` | ends PortfolioServer | PortfolioServer's own `40`, `41`, `4F` (reference: `golden/portfolioserver/`; the ROM ignores them) |
| `61-files.txt` | yes | PortfolioServer's `42`–`45`: delete, make and remove folders, free space on A: |
| `51-longblock.txt` | ends server mode | a 120-byte command block |
| `52-nofinish.txt` | ends server mode | a list request where the finish block belongs |

## Recording a run

1. Put `MKFIX.COM` on the Portfolio (`make MKFIX.COM`, then
   `rpfolio -f -t MKFIX.COM 'C:\MKFIX.COM'` while the ROM server runs).
2. On the Portfolio, run `C:\MKFIX` at the DOS prompt. It must end with
   "All done".
3. Start the server under test: the ROM (Setup → File transfer → Server)
   or `C:\SERVER`.
4. From the Mac: `tests/probe.sh rom 10-list.txt 20-receive.txt
   30-send.txt 40-odd.txt` (or `portfolioserver` instead of `rom`). These four run
   in order on one MKFIX: 30 and 40 change the files, and 40 expects what
   30 left.
5. Each of cases 45–52 needs a fresh start of server mode first (45–47
   leave a smaller block size behind, 47–52 end server mode), so run them
   one at a time, restarting the server in between.

The "no drive" case in `10-list.txt` lists the current folder, `C:\`, so
its recording depends on what is in `C:\`: `TEST.TXT`, `MKFIX.COM` and
`SERVER.COM` (re-recorded 2026-11-14 after the rename). Re-record it from
the ROM if that changes.

Against PortfolioServer, cases 47, 51 and 52 are expected to differ after the
bad block: the ROM leaves server mode, PortfolioServer carries on (see
"Where PortfolioServer differs" in [../docs/protocol.md](../docs/protocol.md)).

What the ROM does in each case is summarised in
[../docs/rom-behaviour.md](../docs/rom-behaviour.md).
