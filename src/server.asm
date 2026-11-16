; SERVER.COM - PortfolioServer, a file transfer server for the Atari Portfolio
;
; Replaces the ROM's Setup -> File transfer -> Server, speaking the same
; protocol over the parallel port module, so transfolio / rpfolio works
; unchanged. Esc quits.
;
; It copies the ROM's behaviour as recorded in docs/rom-behaviour.md,
; including the odd parts: the block size only ever shrinks, the command
; buffer is never cleared, error headers keep the previous file's details.
;
; Build: nasm -f bin -o SERVER.COM src/server.asm

        cpu     8086
        org     100h

BUFSIZE         equ     7000h           ; largest block, as the ROM
MAXPATH         equ     79              ; longest path transfolio sends
CMD_MAX         equ     90              ; longest command block accepted
FIN_MAX         equ     16              ; longest finish block accepted
WAIT_TRIES      equ     20              ; x 500 ms, waiting mid-command

; Int 61h function 30h sub-services (Portfolio TRG 3.3.1)
FT_SEND         equ     3000h           ; DS:DX buffer, CX length
FT_RECV         equ     3001h           ; DS:DX buffer, CX size -> CX length
FT_OPEN         equ     3002h
FT_CLOSE        equ     3003h
FT_WAIT         equ     3004h           ; wait 500 ms

; Error codes returned in DL
FTE_OK          equ     0
FTE_TIMEOUT     equ     2
FTE_NOPORT      equ     5
FTE_IDLE        equ     6               ; not in the TRG: seen on a real
                                        ; machine when no client answers

; Reply status bytes
ST_OK           equ     20h             ; found / exists / done
ST_NEW          equ     21h             ; 02: not found; 03: new file
ST_BAD          equ     10h             ; wildcard; 03: failed

; Final 03 acknowledgement bytes 1-2 on the HPC-004 (HPC-006: D8 39)
ACK_1           equ     0D7h
ACK_2           equ     39h

VERSION_MAJOR   equ     0
VERSION_MINOR   equ     5

; DOS DTA offsets
DTA_ATTR        equ     15h
DTA_TIME        equ     16h
DTA_DATE        equ     18h
DTA_SIZE        equ     1Ah
DTA_NAME        equ     1Eh

start:
        ; Is there room for our buffers? PSP:0002 is the first segment
        ; past our memory block.
        mov     ax, [2]
        mov     bx, cs
        sub     ax, bx                  ; paragraphs we own
        mov     bx, mem_end + 15
        mov     cl, 4
        shr     bx, cl                  ; paragraphs we need
        cmp     ax, bx
        jae     .mem_ok
        mov     dx, msg_nomem
        jmp     fail
.mem_ok:
        mov     sp, stack_top
        cld

        mov     dx, msg_banner
        call    print_str

        mov     ax, FT_OPEN
        int     61h
        cmp     dl, FTE_NOPORT
        jne     .port_ok
        mov     dx, msg_noport
        jmp     fail
.port_ok:
        mov     dx, dta                 ; all FindFirst/Next use our DTA
        mov     ah, 1Ah
        int     21h

; ---------------------------------------------------------------------------
; Idle loop: wait for a command block. Each receive sends 5A and times out
; after 500 ms, so the client sees 5A repeatedly, as with the ROM server.
; We only peek at the keyboard (Int 16h fn 01h); the Portfolio powers down
; only inside fn 00h's wait, so it stays on while serving.
;
; Commands land in cmdbuf, which is never cleared: like the ROM, a short
; block only replaces the bytes it carries.
; ---------------------------------------------------------------------------
main_loop:
        mov     ah, 01h
        int     16h
        jz      .no_key
        mov     ah, 00h                 ; key is waiting, so this won't block
        int     16h
        cmp     al, 1Bh                 ; Esc
        je      quit
.no_key:
        mov     dx, cmdbuf
        mov     cx, CMD_MAX
        mov     ax, FT_RECV
        int     61h
        cmp     dl, FTE_OK
        je      .got_block
        cmp     dl, FTE_TIMEOUT
        je      main_loop               ; nobody there yet
        cmp     dl, FTE_IDLE
        je      main_loop
        call    show_error              ; e.g. a block longer than CMD_MAX:
        call    wait_500ms              ; the ROM gives up, we carry on
        jmp     main_loop

.got_block:
        jcxz    main_loop
        mov     al, [cmdbuf]
        cmp     al, 06h
        je      cmd_list
        cmp     al, 02h
        je      cmd_get
        cmp     al, 03h
        je      cmd_put
        cmp     al, 04h                 ; ROM: undocumented, leaves server
        je      quit
        ; PortfolioServer's own commands (the ROM ignores them)
        cmp     al, 40h
        je      cmd_info
        cmp     al, 41h
        je      cmd_dir
        cmp     al, 42h
        je      cmd_delete
        cmp     al, 43h
        je      cmd_mkdir
        cmp     al, 44h
        je      cmd_rmdir
        cmp     al, 45h
        je      cmd_free
        cmp     al, 4Fh
        je      cmd_quit
        ; anything else (01, 05, 00, 20, 46...): the ROM ignores it
        mov     dx, msg_unknown
        call    print_str
        mov     al, [cmdbuf]
        call    print_hex8
        call    print_crlf
        jmp     main_loop

; ---------------------------------------------------------------------------
; 06  List files. Request: 06, size (2), pattern ASCIIZ.
;     Reply: count (u16), names, each NUL-terminated. Plain files only.
; ---------------------------------------------------------------------------
cmd_list:
        call    lower_blocksize
        mov     si, cmdbuf + 3
        call    copy_path
        mov     dx, msg_list
        call    show_path

        mov     di, buf + 2
        xor     bp, bp                  ; count
        mov     dx, path
        xor     cx, cx                  ; attribute 0: plain files
        mov     ah, 4Eh
        int     21h
        jc      .reply
.entry:
        cmp     di, buf + BUFSIZE - 13  ; room for a full 8.3 name + NUL?
        ja      .reply
        mov     si, dta + DTA_NAME
.copy:
        lodsb
        stosb
        test    al, al
        jnz     .copy
        inc     bp
        mov     ah, 4Fh
        int     21h
        jnc     .entry
.reply:
        mov     [buf], bp
        mov     cx, di
        sub     cx, buf
        mov     dx, buf
        call    send_block
        jmp     main_loop

; ---------------------------------------------------------------------------
; 02  Receive file (Portfolio -> client). Request: 02, size (2), path.
;     Reply: header (11): status, block size, time, date, size (u32); then
;     the data in blocks of the block size; then the client's finish block.
;     On status 21 (not found) or 10 (wildcard) the header's bytes 3-10
;     are left as they were, from the last file sent, and nothing follows.
; ---------------------------------------------------------------------------
cmd_get:
        call    lower_blocksize
        mov     si, cmdbuf + 3
        call    copy_path
        mov     dx, msg_get
        call    show_path

        mov     ax, [blocksize]
        mov     [hdr + 1], ax
        mov     byte [hdr], ST_BAD
        call    has_wildcard
        jc      .header_only
        mov     byte [hdr], ST_NEW
        mov     dx, path
        xor     cx, cx                  ; attribute 0: hidden/system missing
        mov     ah, 4Eh
        int     21h
        jc      .header_only
        mov     dx, path
        mov     ax, 3D00h               ; open for reading
        int     21h
        jc      .header_only
        mov     [handle], ax

        mov     ax, [dta + DTA_TIME]
        mov     [hdr + 3], ax
        mov     ax, [dta + DTA_DATE]
        mov     [hdr + 5], ax
        mov     ax, [dta + DTA_SIZE]
        mov     [hdr + 7], ax
        mov     [remain], ax
        mov     ax, [dta + DTA_SIZE + 2]
        mov     [hdr + 9], ax
        mov     [remain + 2], ax
        mov     byte [hdr], ST_OK

        mov     dx, hdr
        mov     cx, 11
        call    send_block
        jc      .close
.next_block:
        call    next_chunk              ; CX = min(block size, remain)
        jcxz    .sent
        mov     bx, [handle]
        mov     dx, buf
        mov     ah, 3Fh
        int     21h
        jc      .close
        cmp     ax, cx
        jne     .close                  ; file shorter than its size?
        mov     dx, buf
        call    send_data               ; (the BIOS may not keep CX)
        jc      .close
        mov     cx, [chunk]
        call    count_down              ; remain -= CX
        jmp     .next_block
.sent:
        call    close_file
        ; The client ends with 20 00 03.
        mov     dx, finbuf
        mov     cx, FIN_MAX
        call    recv_wait
        jmp     main_loop
.close:
        call    close_file
        jmp     main_loop

.header_only:
        mov     al, [hdr]
        mov     dx, w_notfound
        cmp     al, ST_NEW
        je      .show
        mov     dx, w_wildcard
.show:
        call    show_status
        mov     dx, hdr
        mov     cx, 11
        call    send_block
        jmp     main_loop

; ---------------------------------------------------------------------------
; 03  Send file (client -> Portfolio). Request: 03, size (2), time, date,
;     size (u32), path at offset 11.
;     Reply (3): status, block size. 21 = new: data follows. 20 = exists:
;     the client sends 05 00 70 (overwrite, data follows) or 00 00 00
;     (cancel). 10 = wildcard: nothing follows.
;     After the data: 20 D7 39, or 10 D7 39 if the file couldn't be
;     written. Like the ROM, a failure is reported after the first data
;     block that can't be written, without waiting for the rest; a
;     partly written file is removed.
; ---------------------------------------------------------------------------
cmd_put:
        call    lower_blocksize
        mov     ax, [cmdbuf + 3]
        mov     [put_time], ax
        mov     ax, [cmdbuf + 5]
        mov     [put_date], ax
        mov     ax, [cmdbuf + 7]
        mov     [remain], ax
        mov     ax, [cmdbuf + 9]
        mov     [remain + 2], ax
        mov     si, cmdbuf + 11
        call    copy_path
        mov     dx, msg_put
        call    show_path

        mov     ax, [blocksize]
        mov     [reply + 1], ax
        mov     byte [reply], ST_BAD
        call    has_wildcard
        jc      .wildcard
        mov     byte [reply], ST_NEW
        mov     dx, path
        xor     cx, cx                  ; attribute 0, as the ROM
        mov     ah, 4Eh
        int     21h
        jc      .new
        mov     byte [reply], ST_OK     ; exists: overwrite or cancel?
        mov     dx, reply
        mov     cx, 3
        call    send_block
        jc      .done
        mov     dx, cmdbuf
        mov     cx, CMD_MAX
        call    recv_wait
        jc      .done
        cmp     byte [cmdbuf], 05h
        jne     .done                   ; 00 (or anything else): cancel
        call    lower_blocksize
        jmp     .create
.new:
        mov     dx, reply
        mov     cx, 3
        call    send_block
        jc      .done
        ; "New" to the ROM, but a hidden or system file of that name may
        ; exist: the ROM then leaves it alone and fails (recorded).
        ; Get attributes (4300h) finds a file of any attribute.
        mov     byte [created], 0
        mov     byte [put_failed], 1
        mov     dx, path
        mov     ax, 4300h               ; get attributes: any file that exists
        int     21h
        jc      .create
        test    cl, 10h                 ; a folder: create fails anyway
        jz      .data
.create:
        mov     byte [created], 0
        mov     byte [put_failed], 0
        mov     byte [write_failed], 0
        mov     dx, path
        xor     cx, cx
        mov     ah, 3Ch                 ; create / truncate
        int     21h
        jnc     .opened
        mov     byte [put_failed], 1    ; told after the first data block
        jmp     .data
.opened:
        mov     [handle], ax
        mov     byte [created], 1

.data:
        mov     ax, [remain]
        or      ax, [remain + 2]
        jz      .finish                 ; zero-length file: no data blocks
.next_block:
        mov     dx, buf
        mov     cx, [blocksize]
        call    recv_wait
        jc      .abort                  ; client gone: drop the file
        cmp     byte [put_failed], 0
        jne     .failed
        ; A client always sends min(block size, bytes left). A block of any
        ; other size is a new client's command after the old one died
        ; mid-upload: drop the upload and handle the command. (The ROM
        ; would take it as data and get stuck.)
        push    cx                      ; the size received
        call    next_chunk              ; CX = the size we expect
        mov     ax, cx
        pop     cx
        mov     [chunk], cx             ; (next_chunk overwrote it)
        cmp     cx, ax
        jne     .stray
        cmp     byte [write_failed], 0
        jne     .written                ; take the rest, report at the end
        jcxz    .written
        mov     [chunk], cx
        mov     bx, [handle]
        mov     dx, buf
        mov     ah, 40h
        int     21h
        mov     cx, [chunk]
        jc      .write_error
        cmp     ax, cx
        je      .written
.write_error:                           ; e.g. disk full: like the ROM, take
        mov     byte [write_failed], 1  ; the remaining blocks, then fail
.written:
        call    count_down
        mov     ax, [remain]
        or      ax, [remain + 2]
        jnz     .next_block

.finish:
        cmp     byte [put_failed], 0
        jne     .failed
        cmp     byte [write_failed], 0
        jne     .failed
        mov     bx, [handle]
        mov     cx, [put_time]
        mov     dx, [put_date]
        mov     ax, 5701h
        int     21h
        call    close_file
        mov     byte [reply], ST_OK
        mov     dx, w_ok
        jmp     .ack
.failed:
        ; The ROM deletes the target by name when a put fails, even a
        ; hidden file it never wrote to (recorded: C:\PT\HID.TXT went).
        call    drop_file
        mov     dx, path
        mov     ah, 41h
        int     21h
        mov     byte [reply], ST_BAD
        mov     dx, w_failed
.ack:
        mov     byte [reply + 1], ACK_1
        mov     byte [reply + 2], ACK_2
        jmp     .reply_only
.wildcard:
        mov     dx, w_wildcard
.reply_only:                            ; DX = the word for the log
        mov     al, [reply]
        call    show_status
        mov     dx, reply
        mov     cx, 3
        call    send_block
.done:
        jmp     main_loop
.abort:
        call    drop_file
        jmp     main_loop
.stray:
        call    drop_file
        mov     dx, msg_stray
        call    print_str
        mov     cx, [chunk]
        cmp     cx, CMD_MAX
        ja      .done                   ; too long for a command: just drop it
        mov     si, buf                 ; as if it had come in as a command:
        mov     di, cmdbuf              ; only its own bytes replace cmdbuf's
        rep     movsb
        mov     cx, [chunk]
        jmp     main_loop.got_block

; ---------------------------------------------------------------------------
; PortfolioServer's own commands, 40-4F. None of them changes the block size.
; ---------------------------------------------------------------------------

; 40  Info. Reply (8): 20, block size, 'P' 'S', version major, minor, 0.
;     Sent to the ROM, 40 gets no reply: that is how a client tells them
;     apart.
cmd_info:
        mov     dx, msg_info
        call    print_str
        mov     byte [buf], ST_OK
        mov     ax, [blocksize]
        mov     [buf + 1], ax
        mov     word [buf + 3], 'PS'    ; 'P' then 'S'
        mov     byte [buf + 5], VERSION_MAJOR
        mov     byte [buf + 6], VERSION_MINOR
        mov     byte [buf + 7], 0
        mov     dx, buf
        mov     cx, 8
        call    send_block
        jmp     main_loop

; 41  Directory listing. Request: 41, size (2), pattern ASCIIZ (as 06).
;     Reply: count (u16), flags (bit 0: truncated), 0, then per entry 22
;     bytes: attributes, time, date, size (u32), name (13, NUL-padded).
;     Folders included; . and .. left out.
cmd_dir:
        mov     si, cmdbuf + 3
        call    copy_path
        mov     dx, msg_dir
        call    show_path

        mov     di, buf + 4
        xor     bp, bp                  ; count
        mov     byte [buf + 2], 0       ; flags
        mov     byte [buf + 3], 0
        mov     dx, path
        mov     cx, 16h                 ; folders, hidden, system too
        mov     ah, 4Eh
        int     21h
        jc      .reply
.entry:
        cmp     byte [dta + DTA_NAME], '.'
        je      .next                   ; . and ..
        cmp     di, buf + BUFSIZE - 22
        jbe     .room
        or      byte [buf + 2], 1       ; truncated
        jmp     .reply
.room:
        mov     si, dta + DTA_ATTR      ; attribute, time, date, size
        mov     cx, 9
        rep     movsb
        mov     si, dta + DTA_NAME      ; name, NUL-padded to 13
        mov     cx, 13
.name:
        lodsb
        stosb
        dec     cx
        test    al, al
        jnz     .name
        rep     stosb                   ; AL = 0: pad the rest
        inc     bp
.next:
        mov     ah, 4Fh
        int     21h
        jnc     .entry
.reply:
        mov     [buf], bp
        mov     cx, di
        sub     cx, buf
        mov     dx, buf
        call    send_block
        jmp     main_loop

; 42  Delete file, 43 Make folder, 44 Remove folder.
;     Request: code, size (2), path ASCIIZ (as 06).
;     Reply (3): 20 00 00, or 10 and the DOS error (u16).
;     Wildcards are refused (error 2) and so is drive B: (error 0Fh): on
;     the Portfolio B: is a phantom of the card slot, and DOS would stop
;     and ask on the Portfolio's screen for a disk.
cmd_delete:
        mov     dx, msg_delete
        mov     byte [dos_fn], 41h
        jmp     path_command
cmd_mkdir:
        mov     dx, msg_mkdir
        mov     byte [dos_fn], 39h
        jmp     path_command
cmd_rmdir:
        mov     dx, msg_rmdir
        mov     byte [dos_fn], 3Ah
path_command:
        push    dx
        mov     si, cmdbuf + 3
        call    copy_path
        pop     dx
        call    show_path
        call    check_drive_b
        jc      .refuse
        call    has_wildcard            ; (uses AL)
        mov     ax, 2                   ; "file not found" (keeps CF)
        jc      .failed
        mov     dx, path
        mov     ah, [dos_fn]
        int     21h
        jc      .failed
        mov     byte [buf], ST_OK
        mov     word [buf + 1], 0
        jmp     .reply
.refuse:
        mov     ax, 0Fh                 ; "invalid drive"
.failed:
        mov     byte [buf], ST_BAD
        mov     [buf + 1], ax
.reply:
        call    show_buf_result
        mov     dx, buf
        mov     cx, 3
        call    send_block
        jmp     main_loop

; 45  Free space. Request: 45, size (2), a path starting with the drive
;     (e.g. C: or A:\; anything else means the current drive).
;     Reply (11): status, free bytes (u32), total bytes (u32), 0 (u16).
;     On failure: 10, the DOS error (u16), then zeros. Drive B: is refused.
cmd_free:
        mov     si, cmdbuf + 3
        call    copy_path
        mov     dx, msg_free
        call    show_path
        mov     di, buf                 ; reply starts as all zeros
        mov     cx, 11
        xor     al, al
        rep     stosb
        call    check_drive_b
        jc      .bad_drive
        xor     dl, dl                  ; 0: current drive
        cmp     byte [path + 1], ':'
        jne     .ask
        mov     dl, [path]
        and     dl, 0DFh                ; upper case
        sub     dl, 'A' - 1             ; A: = 1
        cmp     dl, 26
        ja      .bad_drive
        test    dl, dl
        jz      .bad_drive
.ask:
        mov     ah, 36h
        int     21h
        cmp     ax, 0FFFFh
        je      .bad_drive
        mov     [free_clusters], bx
        mov     [total_clusters], dx
        mul     cx                      ; bytes per cluster (fits 16 bits)
        mov     [cluster_bytes], ax
        mul     word [free_clusters]
        mov     [buf + 1], ax
        mov     [buf + 3], dx
        mov     ax, [cluster_bytes]
        mul     word [total_clusters]
        mov     [buf + 5], ax
        mov     [buf + 7], dx
        mov     byte [buf], ST_OK
        jmp     .reply
.bad_drive:
        mov     byte [buf], ST_BAD
        mov     word [buf + 1], 0Fh     ; "invalid drive"
.reply:
        call    show_buf_result
        mov     dx, buf
        mov     cx, 11
        call    send_block
        jmp     main_loop

; 4F  Quit. Reply (3): 20 00 00, then the server stops.
cmd_quit:
        mov     dx, msg_quitcmd
        call    print_str
        mov     byte [buf], ST_OK
        mov     word [buf + 1], 0
        mov     dx, buf
        mov     cx, 3
        call    send_block
        jmp     quit

; ---------------------------------------------------------------------------
; Helpers
; ---------------------------------------------------------------------------

; The ROM keeps one block size, 7000h at start, and lowers it to the
; buffer size in any request (bytes 1-2) that is smaller. It never goes
; back up. (A size of 0 hasn't been seen; it is ignored.)
lower_blocksize:
        mov     ax, [cmdbuf + 1]
        test    ax, ax
        jz      .keep
        cmp     ax, [blocksize]
        jae     .keep
        mov     [blocksize], ax
.keep:
        ret

; Copy the ASCIIZ path at SI into path, at most MAXPATH chars.
copy_path:
        mov     di, path
        mov     cx, MAXPATH
.next:
        lodsb
        stosb
        test    al, al
        jz      .done
        loop    .next
        mov     byte [di], 0
.done:
        ret

; CF set if path starts with B: (or b:).
check_drive_b:
        cmp     byte [path + 1], ':'
        jne     .no
        mov     al, [path]
        and     al, 0DFh
        cmp     al, 'B'
        jne     .no
        stc
        ret
.no:
        clc
        ret

; CF set if path contains * or ?.
has_wildcard:
        mov     si, path
.next:
        lodsb
        test    al, al
        jz      .none
        cmp     al, '*'
        je      .wild
        cmp     al, '?'
        jne     .next
.wild:
        stc
        ret
.none:
        clc
        ret

; CX = min(blocksize, remain).
next_chunk:
        mov     cx, [blocksize]
        cmp     word [remain + 2], 0
        jne     .done
        cmp     cx, [remain]
        jbe     .done
        mov     cx, [remain]
.done:
        mov     [chunk], cx
        ret

; remain -= CX, stopping at 0.
count_down:
        sub     [remain], cx
        sbb     word [remain + 2], 0
        jnc     .done
        mov     word [remain], 0
        mov     word [remain + 2], 0
.done:
        ret

close_file:
        mov     bx, [handle]
        mov     ah, 3Eh
        int     21h
        ret

; Close and delete a file this put created (if it got that far).
drop_file:
        cmp     byte [created], 0
        je      .done
        call    close_file
        mov     dx, path
        mov     ah, 41h
        int     21h
        mov     byte [created], 0
.done:
        ret

; Send one data block of a download: CX bytes from DX, one try. A live
; client takes the next block at once; one that doesn't is gone, and
; retrying would feed the rest of the file to the next client's start-up
; handshake, which acknowledges every bit until it sees a 5A byte.
send_data:
        mov     ax, FT_SEND
        int     61h
        cmp     dl, FTE_OK
        je      .ok
        call    show_error
        stc
        ret
.ok:
        clc
        ret

; Send a reply: CX bytes from DX as one block. CF set on failure.
; Like the ROM, keep trying while the client isn't listening (recorded: the
; ROM's 03 failure reply waited over 3 s for a client busy sending).
send_block:
        mov     [rw_buf], dx
        mov     [rw_size], cx
        mov     byte [rw_tries], WAIT_TRIES
.again:
        mov     dx, [rw_buf]
        mov     cx, [rw_size]
        mov     ax, FT_SEND
        int     61h
        cmp     dl, FTE_OK
        je      .ok
        cmp     dl, FTE_TIMEOUT
        je      .retry
        cmp     dl, FTE_IDLE
        je      .retry
        call    show_error
        call    wait_500ms
        stc
        ret
.retry:
        dec     byte [rw_tries]
        jnz     .again
        mov     dx, msg_gaveup
        call    print_str
        stc
        ret
.ok:
        clc
        ret

; Receive a block into DX (size CX) in the middle of a command, waiting up
; to WAIT_TRIES x 500 ms. CX = length; CF set on failure.
recv_wait:
        mov     [rw_buf], dx
        mov     [rw_size], cx
        mov     byte [rw_tries], WAIT_TRIES
.again:
        mov     dx, [rw_buf]
        mov     cx, [rw_size]
        mov     ax, FT_RECV
        int     61h
        cmp     dl, FTE_OK
        je      .ok
        cmp     dl, FTE_TIMEOUT
        je      .retry
        cmp     dl, FTE_IDLE
        je      .retry
        call    show_error
        call    wait_500ms
        stc
        ret
.retry:
        dec     byte [rw_tries]
        jnz     .again
        mov     dx, msg_gaveup
        call    print_str
        stc
        ret
.ok:
        clc
        ret

wait_500ms:
        mov     ax, FT_WAIT
        int     61h
        ret

; Print the '$' message at DX, then path, then a new line.
show_path:
        call    print_str
        mov     dx, path
        call    print_asciiz
        jmp     print_crlf

; Print " -> word (XX)": DX = the word ('$' string), AL = the status byte.
; The log only: the reply itself is sent separately, from memory.
show_status:
        call    show_word
        jmp     print_close

; Print " -> word (XX" without the closing bracket.
show_word:
        mov     [st_code], al
        push    dx
        mov     dx, msg_status
        call    print_str
        pop     dx
        call    print_str
        mov     dx, msg_open
        call    print_str
        mov     al, [st_code]
        jmp     print_hex8

; Show the result of a 42-45 reply in buf: " -> OK (20)", or for a failure
; the DOS error (buf + 1) as a word and both bytes, e.g.
; " -> access denied (10 05)". An unlisted error shows as "failed".
show_buf_result:
        mov     al, [buf]
        mov     dx, w_ok
        cmp     al, ST_OK
        je      show_status
        mov     ah, [buf + 1]
        mov     [dos_err], ah
        mov     dx, w_failed
        mov     si, dos_words
.find:
        lodsb                           ; error code, 0 ends the table
        test    al, al
        jz      .print
        cmp     al, [dos_err]
        lodsw                           ; its word (LODS keeps the flags)
        jne     .find
        mov     dx, ax
.print:
        mov     al, [buf]
        call    show_word
        mov     dl, ' '
        mov     ah, 02h
        int     21h
        mov     al, [dos_err]
        call    print_hex8
        jmp     print_close

; Print the transfer error code in DL: "Transfer error: checksum (03)" for
; the ones a client can cause, "Transfer error 04" for the rest.
show_error:
        mov     [st_code], dl
        mov     dx, msg_error
        call    print_str
        mov     dx, w_toolong
        cmp     byte [st_code], 1       ; block longer than the buffer
        je      .named
        mov     dx, w_checksum
        cmp     byte [st_code], 3
        je      .named
        mov     dl, ' '
        mov     ah, 02h
        int     21h
        mov     al, [st_code]
        call    print_hex8
        jmp     print_crlf
.named:
        push    dx
        mov     dx, msg_colon
        call    print_str
        pop     dx
        call    print_str
        mov     dx, msg_open
        call    print_str
        mov     al, [st_code]
        call    print_hex8
        jmp     print_close

; Print ")" and a new line.
print_close:
        mov     dx, msg_close
        jmp     print_str

; Print the '$'-terminated string at DX.
print_str:
        mov     ah, 09h
        int     21h
        ret

; Print the ASCIIZ string at DX.
print_asciiz:
        mov     si, dx
.next:
        lodsb
        test    al, al
        jz      .done
        mov     dl, al
        mov     ah, 02h
        int     21h
        jmp     .next
.done:
        ret

print_crlf:
        mov     dx, msg_crlf
        jmp     print_str

; Print AL as two hex digits.
print_hex8:
        push    ax
        mov     cl, 4
        shr     al, cl
        call    .digit
        pop     ax
        and     al, 0Fh
.digit:
        add     al, '0'
        cmp     al, '9'
        jbe     .out
        add     al, 'A' - '9' - 1
.out:
        mov     dl, al
        mov     ah, 02h
        int     21h
        ret

quit:
        mov     ax, FT_CLOSE
        int     61h
        mov     dx, msg_bye
        call    print_str
        mov     ax, 4C00h
        int     21h

; DX = message. Print it and exit with code 1.
fail:
        call    print_str
        mov     ax, 4C01h
        int     21h

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------
msg_banner      db      'PortfolioServer 0.5 - Esc quits', 13, 10, '$'
msg_noport      db      'No parallel port module', 13, 10, '$'
msg_nomem       db      'Not enough memory', 13, 10, '$'
msg_bye         db      'Server stopped', 13, 10, '$'
msg_list        db      'List $'
msg_get         db      'Get $'
msg_put         db      'Put $'
msg_info        db      'Info', 13, 10, '$'
msg_dir         db      'Dir $'
msg_quitcmd     db      'Quit requested', 13, 10, '$'
msg_delete      db      'Delete $'
msg_mkdir       db      'Make folder $'
msg_rmdir       db      'Remove folder $'
msg_free        db      'Free space $'
msg_status      db      ' -> $'
msg_unknown     db      'Ignored $'
msg_error       db      'Transfer error$'
msg_colon       db      ': $'
msg_open        db      ' ($'
msg_close       db      ')', 13, 10, '$'

; Words for the log's status lines (the codes are printed after them)
w_ok            db      'OK$'
w_notfound      db      'not found$'
w_wildcard      db      'wildcard$'
w_failed        db      'failed$'
w_nopath        db      'no path$'
w_denied        db      'access denied$'
w_baddrive      db      'bad drive$'
w_toolong       db      'too long$'
w_checksum      db      'checksum$'

; DOS error -> word, for 42-45 failures. 0 ends the table.
dos_words       db      02h
                dw      w_notfound
                db      03h
                dw      w_nopath
                db      05h
                dw      w_denied
                db      0Fh
                dw      w_baddrive
                db      0
msg_gaveup      db      'No answer, gave up', 13, 10, '$'
msg_stray       db      'New client: upload dropped', 13, 10, '$'
msg_crlf        db      13, 10, '$'

blocksize       dw      BUFSIZE         ; only ever lowered, see above
hdr             times 11 db 0           ; 02 header, kept between commands
cmdbuf          times 128 db 0          ; never cleared, see main_loop

; ---------------------------------------------------------------------------
; Uninitialised data, not stored in the .COM file
; ---------------------------------------------------------------------------
        section .bss
        alignb  2
remain          resd    1               ; bytes still to send or receive
handle          resw    1
chunk           resw    1
put_time        resw    1
put_date        resw    1
rw_buf          resw    1
rw_size         resw    1
rw_tries        resb    1
created         resb    1
put_failed      resb    1               ; couldn't create: fail after block 1
write_failed    resb    1               ; a write failed: fail at the end
dos_fn          resb    1               ; 41h, 39h or 3Ah for 42-44
st_code         resb    1               ; code being logged
dos_err         resb    1               ; DOS error being logged
                alignb  2
free_clusters   resw    1
total_clusters  resw    1
cluster_bytes   resw    1
reply           resb    3
finbuf          resb    FIN_MAX
                alignb  2
dta             resb    44
path            resb    MAXPATH + 1
                alignb  2
stack           resb    512
stack_top:
buf             resb    BUFSIZE
mem_end:
