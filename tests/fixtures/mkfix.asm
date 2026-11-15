; MKFIX.COM - rebuild the compatibility test files on the Portfolio
;
; Deletes C:\PT and A:\PT (two levels deep, whatever is in them), plus
; A:\GAMES, A:\CARDTEST.TXT and A:\PIN.COM to make room on the card, and
; creates them again with fixed contents, attributes, times and dates, so
; every recording run starts from the same state. Nothing else outside the
; PT folders is touched. See tests/README.md.
;
; File contents: byte i of every file is i mod 251 (so a block that ends
; up shifted by 28,672 bytes doesn't hash the same).
;
; Build: nasm -f bin -o MKFIX.COM tests/fixtures/mkfix.asm

        cpu     8086
        org     100h

FIX_TIME        equ     6000h           ; 12:00:00
FIX_DATE        equ     2821h           ; 2000-01-01
CHUNK           equ     512

start:
        cld
        mov     dx, msg_banner
        call    print_str
        mov     dx, dta
        mov     ah, 1Ah
        int     21h

        ; Make the known hidden and system files plain first, so nothing
        ; can stop the wipe below (harmless if they're already gone).
        mov     si, unhide_list
.unhide:
        cmp     byte [si], 0
        je      .wipe_all
        mov     dx, si
        xor     cx, cx
        mov     ax, 4301h
        int     21h
.uskip:
        lodsb
        test    al, al
        jnz     .uskip
        jmp     .unhide

.wipe_all:
        mov     si, wipe_list
.wipe:
        cmp     byte [si], 0
        je      .create
        mov     dx, si
        call    wipe_dir
.skip:
        lodsb                           ; past this path's NUL
        test    al, al
        jnz     .skip
        jmp     .wipe

.create:
        ; Files outside PT that get in the way (the A: card is small)
        mov     si, delete_list
.del:
        cmp     byte [si], 0
        je      .make
        mov     dx, si
        xor     cx, cx
        mov     ax, 4301h
        int     21h
        mov     dx, si
        mov     ah, 41h
        int     21h
.dskip:
        lodsb
        test    al, al
        jnz     .dskip
        jmp     .del

.make:
        mov     si, fix_list
.entry:
        lodsb                           ; attribute, FFh = end
        cmp     al, 0FFh
        je      .done
        mov     [cur_attr], al
        lodsw
        mov     [cur_size], ax
        mov     [cur_path], si
        mov     dx, si
        call    print_asciiz
        cmp     byte [cur_attr], 10h
        jne     .file
        mov     dx, [cur_path]          ; folder
        mov     ah, 39h
        int     21h
        jmp     .result
.file:
        call    make_file
.result:
        jc      .bad
        mov     dx, msg_ok
        call    print_str
        jmp     .next
.bad:
        push    ax
        mov     dx, msg_fail
        call    print_str
        pop     ax
        call    print_hex8
        mov     dx, msg_crlf
        call    print_str
        inc     byte [failures]
.next:
        mov     si, [cur_path]
.past:
        lodsb
        test    al, al
        jnz     .past
        jmp     .entry

.done:
        mov     dl, 1                   ; A:
        call    show_free
        mov     dl, 3                   ; C:
        call    show_free
        mov     dx, msg_done
        cmp     byte [failures], 0
        je      .exit
        mov     dx, msg_errors
.exit:
        call    print_str
        mov     ax, 4C00h
        int     21h

; ---------------------------------------------------------------------------
; Delete every file in the folder at DX (hidden, system and read-only too),
; then the folder itself. Errors are ignored: it may not exist.
; ---------------------------------------------------------------------------
wipe_dir:
        push    si
        mov     [wipe_dirp], dx
        ; pattern = dir + "\*.*"
        mov     si, dx
        mov     di, pattern
        call    copy_str
        mov     si, star_dot_star
        call    copy_str_nul
.again:
        ; Find the first file each time: deleting while stepping through
        ; FindNext isn't reliable.
        mov     dx, pattern
        mov     cx, 07h                 ; read-only, hidden, system too
        mov     ah, 4Eh
        int     21h
        jc      .rmdir
        mov     si, [wipe_dirp]         ; name = dir + "\" + found name
        mov     di, name
        call    copy_str
        mov     al, '\'
        stosb
        mov     si, dta + 1Eh
        call    copy_str_nul
        mov     dx, name
        xor     cx, cx                  ; clear attributes so it can go
        mov     ax, 4301h
        int     21h
        mov     dx, name
        mov     ah, 41h
        int     21h
        jnc     .again
        ; can't delete it: give up on this folder rather than loop forever
.rmdir:
        mov     dx, [wipe_dirp]
        mov     ah, 3Ah
        int     21h
        pop     si
        ret

; ---------------------------------------------------------------------------
; Create cur_path with cur_size bytes of the pattern, the fixed time and
; date, and cur_attr. CF set and AL = DOS error on failure.
; ---------------------------------------------------------------------------
make_file:
        mov     dx, [cur_path]
        xor     cx, cx
        mov     ah, 3Ch
        int     21h
        jc      .ret
        mov     [handle], ax
        mov     bp, [cur_size]          ; bytes left
        xor     bl, bl                  ; pattern value
.chunk:
        test    bp, bp
        jz      .stamp
        mov     cx, CHUNK
        cmp     bp, cx
        jae     .fill
        mov     cx, bp
.fill:
        push    cx
        mov     di, chunk
        mov     al, bl
.byte:
        stosb
        inc     al
        cmp     al, 251
        jb      .next
        xor     al, al
.next:
        loop    .byte
        mov     bl, al
        pop     cx
        mov     dx, chunk
        mov     bx, [handle]
        mov     ah, 40h
        int     21h
        jc      .close_fail
        cmp     ax, cx
        jne     .full
        sub     bp, cx
        ; recompute the pattern value: (size - bp) mod 251
        mov     ax, [cur_size]
        sub     ax, bp
        xor     dx, dx
        mov     cx, 251
        div     cx
        mov     bl, dl
        jmp     .chunk
.full:
        mov     ax, 27h                 ; "disk full"
        jmp     .close_fail
.stamp:
        mov     bx, [handle]
        mov     cx, FIX_TIME
        mov     dx, FIX_DATE
        mov     ax, 5701h
        int     21h
        mov     bx, [handle]
        mov     ah, 3Eh
        int     21h
        jc      .ret
        mov     dx, [cur_path]
        xor     ch, ch
        mov     cl, [cur_attr]
        mov     ax, 4301h
        int     21h
.ret:
        ret
.close_fail:
        push    ax
        mov     bx, [handle]
        mov     ah, 3Eh
        int     21h
        pop     ax
        stc
        ret

; ---------------------------------------------------------------------------
; Print "X: n bytes free" for drive DL (1 = A:).
; ---------------------------------------------------------------------------
show_free:
        push    dx
        mov     al, dl
        add     al, 'A' - 1
        mov     dl, al
        mov     ah, 02h
        int     21h
        mov     dx, msg_colon
        call    print_str
        pop     dx
        mov     ah, 36h
        int     21h
        cmp     ax, 0FFFFh
        je      .bad
        mul     cx                      ; bytes per cluster (fits 16 bits)
        mul     bx                      ; DX:AX = free bytes
        call    print_u32
        mov     dx, msg_free
        jmp     print_str
.bad:
        mov     dx, msg_nodrive
        jmp     print_str

; Print DX:AX in decimal.
print_u32:
        xor     cx, cx                  ; digits pushed
.div:
        push    ax
        mov     ax, dx                  ; divide the high word first
        xor     dx, dx
        mov     bx, 10
        div     bx
        mov     si, ax                  ; high quotient
        pop     ax
        div     bx                      ; DX = remainder, AX = low quotient
        push    dx
        inc     cx
        mov     dx, si
        mov     bx, ax
        or      bx, dx
        jnz     .div
.out:
        pop     dx
        add     dl, '0'
        mov     ah, 02h
        int     21h
        loop    .out
        ret

; ---------------------------------------------------------------------------
; Helpers
; ---------------------------------------------------------------------------

; Copy the ASCIIZ string at SI to DI without its NUL (DI ends after it).
copy_str:
        lodsb
        test    al, al
        jz      .end
        stosb
        jmp     copy_str
.end:
        ret

; Copy the ASCIIZ string at SI to DI with its NUL.
copy_str_nul:
        lodsb
        stosb
        test    al, al
        jnz     copy_str_nul
        ret

print_str:
        mov     ah, 09h
        int     21h
        ret

print_asciiz:
        push    si
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
        pop     si
        ret

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

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------
msg_banner      db      'MKFIX: rebuilding C:\PT and A:\PT', 13, 10, '$'
msg_ok          db      ' ok', 13, 10, '$'
msg_fail        db      ' FAIL $'
msg_crlf        db      13, 10, '$'
msg_done        db      'All done', 13, 10, '$'
msg_errors      db      'Finished WITH ERRORS', 13, 10, '$'
msg_colon       db      ': $'
msg_free        db      ' bytes free', 13, 10, '$'
msg_nodrive     db      'no drive', 13, 10, '$'
star_dot_star   db      '\*.*', 0

; Hidden or system files MKFIX makes, to make plain before the wipe.
unhide_list     db      'C:\PT\HID.TXT', 0
                db      'C:\PT\SYS.TXT', 0
                db      0

; Files outside PT to delete. Ends with an empty string.
delete_list     db      'A:\CARDTEST.TXT', 0
                db      'A:\PIN.COM', 0
                db      0

; Folders to empty and remove, innermost first. Ends with an empty string.
wipe_list       db      'C:\PT\SUB', 0
                db      'C:\PT', 0
                db      'A:\PT\SUB', 0
                db      'A:\PT', 0
                db      'A:\GAMES', 0           ; not needed, frees the card
                db      0

; attribute (10h = folder, FFh = end), size (u16), path
%macro fix 3
                db      %1
                dw      %2
                db      %3, 0
%endmacro
fix_list:
        fix     10h,     0, 'C:\PT'
        fix     10h,     0, 'C:\PT\SUB'
        fix     20h,     0, 'C:\PT\EMPTY.TXT'
        fix     20h,   100, 'C:\PT\SMALL.TXT'
        fix     21h,    10, 'C:\PT\RO.TXT'
        fix     22h,    10, 'C:\PT\HID.TXT'
        fix     24h,    10, 'C:\PT\SYS.TXT'
        fix     00h,    10, 'C:\PT\NOARC.TXT'
        fix     20h,    10, 'C:\PT\NOEXT'
        fix     20h,    20, 'C:\PT\SUB\IN.TXT'
        fix     10h,     0, 'A:\PT'
        fix     10h,     0, 'A:\PT\SUB'
        fix     20h, 28672, 'A:\PT\B28672.BIN'
        fix     20h, 28673, 'A:\PT\B28673.BIN'
        fix     20h,    20, 'A:\PT\SUB\IN.TXT'
                db      0FFh

failures        db      0

        section .bss
cur_attr        resb    1
                alignb  2
cur_size        resw    1
cur_path        resw    1
handle          resw    1
wipe_dirp       resw    1
dta             resb    44
pattern         resb    96
name            resb    96
chunk           resb    CHUNK
