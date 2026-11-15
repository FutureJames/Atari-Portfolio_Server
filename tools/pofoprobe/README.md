# pofoprobe

A raw protocol tool for the Portfolio's file transfer server, for the
Raspberry Pi wiring that rpfolio uses. It sends and receives single blocks as
a script says, and logs every byte. Unlike rpfolio it doesn't exit on an
unexpected byte and doesn't hang: every wait for a clock edge times out, the
step is logged as failed, and the script carries on.

It exists to record exactly what the ROM server does (see
[../../docs/rom-behaviour.md](../../docs/rom-behaviour.md) and
[../../tests/](../../tests/)) and to check that PortfolioServer does the same. Its bit and block code follows transfolio
(commit `ab89073`) with the same pins and delays.

## Build and run (on the Pi)

Stop anything else using the port first (for example PiPortfolioDaemon's
`piportfolio` service).

```sh
make install                 # builds ~/pofoprobe
~/pofoprobe examples/smoke.txt
~/pofoprobe -t script.txt    # also print each step's time to stderr
~/pofoprobe - <<'EOF'        # script from stdin
sync
send 06 00 70 "C:\*.*" 00 pad=82
recv
EOF
```

The exit code is 0 if no step failed, 1 otherwise.

## Script

One step per line. `#` starts a comment line.

| Step | Does |
|------|------|
| `sync` | Wait for the server's `5A`, the way rpfolio starts. |
| `send ITEMS…` | Send one block made of the items below (waits for `5A`, sends `A5`, length, data, checksum, checks the echo). |
| `recv [max=N] [show=N] [all] [save=PATH]` | Receive one block (sends `5A`, expects `A5`). Logs the length, an FNV-1a hash and the first 96 bytes (`show=N` or `all` to change that). `max=N` flags a block longer than N, like rpfolio's buffer limits. `save=PATH` appends the data to a file. |
| `peek [N]` | Read N bytes (default 4) of whatever the server sends, e.g. the `5A` of an idle server. |
| `timeout MS` | Time allowed for each clock edge (default 5000). |
| `sleep MS` | Wait. |
| `echo TEXT` | Copy TEXT into the transcript. |

`send` items:

| Item | Bytes |
|------|-------|
| `06`, `A5`… | one byte, two hex digits |
| `"C:\*.*"` | the characters, no NUL (add `00`), no escapes |
| `u16=N`, `u32=N` | little-endian number (decimal or `0x…`) |
| `pad=N` | zeros up to a total of N bytes |
| `fill=N` | N bytes counting 00, 01, … FF, 00 … |
| `file=PATH[:OFFSET[:LENGTH]]` | bytes from a file on the Pi |

## Transcript

```
> send 82: 06 00 70 43 3A 5C 2A 2E 2A 00 …  |..pC:\*.*…|
  ok, checksum DD echoed
< recv 23 fnv=7AE753BB: 02 00 54 45 53 54 …  |..TEST.TXT.POFOSRV.COM.|
  ok, checksum 3D
  ! line 22: expected A5 (block start), got 5A
= 1 error
```

`>` sent block, `<` received block, `!` failure, `=` tool status, `#` echo.
There are no timings in the transcript, so two runs can be compared with
`diff`.
