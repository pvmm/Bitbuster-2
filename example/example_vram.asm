        DEVICE NOSLOT64K
        OUTPUT "EXAMPLE_VRAM.ROM"

        DEFINE BITBUSTER_OPTIMIZE_SPEED

CHGMOD: equ $5F
BAKCLR: equ $F3EA
BDRCLR: equ $F3EB
FORCLR: equ $F3E9

        org $4000

header: db "AB"            ; ROM signature
        dw init             ; INIT
        dw 0                ; STATEMENT
        dw 0                ; DEVICE
        dw 0                ; TEXT
        dw 0,0,0            ; reserved

init:
        xor a
        ld (BAKCLR),a
        ld (BDRCLR),a
        ld (FORCLR),a
        ld a,8
        call CHGMOD         ; set SCREEN 8

        ld hl,gfx           ; compressed image data
        ld de,$0000         ; VRAM destination address (SCREEN 8 start)
        xor a               ; start decompressing new data
.depack_loop:
        push de             ; save VRAM destination address
        call bitbuster_vram.depack
        pop de              ; restore VRAM destination address
        ex de,hl            ; HL = VRAM dest, DE = next compressed block
        add hl,bc           ; advance VRAM destination by decompressed size
        ex de,hl            ; HL = next compressed block, DE = next VRAM dest
        jr nz,.depack_loop  ; continue while blocks remain

.loop_forever:
        jr .loop_forever

        include "../bitbuster_vram.asm"

gfx:
        incbin "MSX.PCK"

        ds $8000 - $, $FF   ; pad to 16KB ROM size
