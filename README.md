# Atari-Portfolio_Server

**PortfolioServer** (`SERVER.COM`) is a file transfer server for the
[Atari Portfolio](https://en.wikipedia.org/wiki/Atari_Portfolio) that runs on
the Portfolio itself. It improves upon the ROM's built-in server
(Setup → File transfer → Server) and adds the commands the ROM lacks:
folder listings with size, date and attributes, deleting files, making and
removing folders, and free space. The ROM's built-in server can't be
removed, so it stays available from the menu.

It speaks the ROM server's protocol over the Parallel Interface, so
[transfolio](https://github.com/skudi/transfolio) / `rpfolio` and anything
built on it keep working unchanged. With the included
[rpfolio patch](patches/rpfolio-portfolioserver.patch) they can use the new
commands too. It should also work with a PC running `FT.COM`, the DOS
program "Atari Portfolio File Transfer" that shipped with the Portfolio
(not tested yet).

[PiPortfolioDaemon](https://github.com/FutureJames/PiPortfolioDaemon),
a web application for managing the Portfolio from a Raspberry Pi, uses them
for folders, delete and free space.

## Features

- **A drop-in replacement for the ROM server.** List (`06`), receive (`02`),
  send (`03`) with overwrite (`05`) and cancel (`00`), and `04` behave
  exactly like the ROM's, byte for byte, including the error replies and the
  ROM's quirks. Every recorded case in [tests/](tests/) matches.
- **Recovers where the ROM gives up.** A client that disappears mid-transfer
  or sends a malformed block doesn't leave it stuck: it goes back to waiting
  for the next command, where the ROM stops with "Communications Error" and
  needs server mode restarting by hand.
- **Fixes a ROM bug:** uploads of exactly 28,672 bytes (one full block)
  work.
- **New commands** (`40`–`45`, `4F`): server version, a listing with folders,
  attributes, size, date and time (including hidden and system files),
  delete a file, make and remove folders, free space, and quit.
- **Keeps the Portfolio awake** while it runs, so it doesn't switch itself
  off in the middle of a session (see [Batteries](#batteries)).
- **Small:** about 2 KB on disk and about 30 KB of RAM while running.

The protocol, every command and every difference from the ROM are described
in [docs/protocol.md](docs/protocol.md). What the ROM server actually does,
as recorded, is in [docs/rom-behaviour.md](docs/rom-behaviour.md).

## Download

The latest `SERVER.COM` is on the
[Releases page](https://github.com/FutureJames/Atari-Portfolio_Server/releases/latest).
To build it yourself, see [Build](#build).

## Install and run

1. On the Portfolio, start the built-in server (Setup → File transfer →
   Server, or **Atari + S**, **F**, **S**).
2. Send `SERVER.COM` to it, for example from a Raspberry Pi:
   `rpfolio -f -t SERVER.COM 'C:\SERVER.COM'`
   (with PiPortfolioDaemon, upload it to `C:\` from the web page).
3. On the Portfolio, press **Esc** to leave the built-in server, then type
   `C:\SERVER` at the DOS prompt and press **Enter**.
4. Use `rpfolio -l`, `-r` and `-t` as with the built-in server.

Press **Esc** on the Portfolio to stop PortfolioServer.

To update it, send the new `SERVER.COM` to `C:\SERVER.COM` while it runs
(it can overwrite itself), then press **Esc** and start it again.

### Batteries

The Portfolio only switches itself off while a program waits for a key.
PortfolioServer never does, so the Portfolio stays on while it runs. Stop it
when you're done.

## Using the new commands with rpfolio

[patches/rpfolio-portfolioserver.patch](patches/rpfolio-portfolioserver.patch)
adds options to transfolio / `rpfolio` for PortfolioServer's commands:

| Option | Does |
|--------|------|
| `-x PATTERN` | lists files and folders with attributes, size, date and time |
| `-i` | shows PortfolioServer's version |
| `-e PATH...` | deletes files |
| `-m PATH...` | makes folders |
| `-k PATH...` | removes empty folders |
| `-s DRIVE...` | shows free and total space, e.g. `-s C: A:` |
| `-q` | stops PortfolioServer |

With the built-in server running instead, these options say so and exit with
code 3, and everything else works as before, so one rpfolio works with
both servers. To build it on a Raspberry Pi (with
[WiringPi](https://github.com/WiringPi/WiringPi) installed):

```sh
git clone https://github.com/skudi/transfolio.git
cd transfolio
git checkout ab89073
git apply /path/to/rpfolio-portfolioserver.patch
cc -DRASPIWIRING -O3 transfolio.c -o rpfolio -lwiringPi
```

The patch applies on its own or together with PiPortfolioDaemon's
`rpfolio-file-size.patch`, in either order.

## Build

Needs [NASM](https://nasm.us/) (on a Mac: `brew install nasm`).

```sh
make
```

This builds `SERVER.COM`, and `MKFIX.COM`, which sets up the test files (see
[tests/README.md](tests/README.md)).

## Tests

[tests/](tests/) has recordings of exactly what the ROM server sends for
each request, including the error cases, and scripts that check
PortfolioServer against them and against real rpfolio transfers. They run
on a Raspberry Pi wired to the Portfolio; see
[tests/README.md](tests/README.md). [tools/pofoprobe](tools/pofoprobe/) is the
raw protocol tool that made the recordings.

## Credits

- **James Adams**: Author of this application.
- **Klaus Peichl**: [transfolio](https://github.com/skudi/transfolio) and its
  [description of the ROM server's protocol](https://www.pofowiki.de/doku.php?id=software:vorstellung:exchanges:transfolio),
  on which the rpfolio patch and pofoprobe are based.
- Atari's *Portfolio Technical Reference Guide* (1st edition, 1989,
  [on archive.org](https://archive.org/details/Protfolio_Technical_Reference_Guide_1st_Edition_Sep_1989)), for the BIOS's parallel port functions.

## License

[MIT](LICENSE), except for the parts based on transfolio, which remain Klaus
Peichl's work; see [LICENSE](LICENSE).
