;	Copyright (c) 2003-2004,2022 Arjan Bakker
;	Bank-aware VRAM-direct BitBuster 2 decompressor for MSX2 (V9938/V9958).
;
;	Reads compressed data from a banked ROM window and writes decompressed
;	output directly to VRAM. Supports 17-bit VRAM addresses (128KB) through
;	VDP register 14, including A16.
;
;	Bank switching: when the compressed stream pointer (HL) reaches the end of
;	the configured window, the next bank is selected and HL wraps to the window
;	start. Configure before use:
;	  BB_BANK_ADDR     - RAM byte holding current bank number
;	  BB_BANK_REG      - ASCII8 mapper register address (default $7000 for
;	                     window $8000-$9FFF)
;	  BB_WINDOW_END_H  - high byte of first address past window (default $A0)
;	  BB_WINDOW_START_H - high byte of window start (default $80)
;	  BB_VRAM_A16_ADDR - RAM byte, bit 2 = VRAM A16 (default 0, no A16)
;
;	Permission is hereby granted, free of charge, to any person obtaining a copy of
;	this software and associated documentation files (the "Software"), to deal in
;	the Software without restriction, including without limitation the rights to
;	use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
;	the Software, and to permit persons to whom the Software is furnished to do so,
;	subject to the following conditions:
;
;	The above copyright notice and this permission notice shall be included in all
;	copies or substantial portions of the Software.
;
;	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
;	FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
;	COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
;	IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
;	CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

		MODULE	bitbuster_vram_bank

		IFNDEF	BITBUSTER_VRAM_DATA_PORT
BITBUSTER_VRAM_DATA_PORT:	EQU	$98
		ENDIF
		IFNDEF	BITBUSTER_VRAM_CMD_PORT
BITBUSTER_VRAM_CMD_PORT:	EQU	$99
		ENDIF
		IFNDEF	BB_BANK_REG
BB_BANK_REG:	EQU	$7000		; ASCII8 page 2 (8000-9FFF)
		ENDIF
		IFNDEF	BB_WINDOW_END_H
BB_WINDOW_END_H:	EQU	$A0
		ENDIF
		IFNDEF	BB_WINDOW_START_H
BB_WINDOW_START_H:	EQU	$80
		ENDIF

; Caller must provide:
;   BB_BANK_ADDR      equ <ram address>  ; current bank number byte
;   BB_VRAM_A16_ADDR  equ <ram address>  ; bit 2 = A16 (optional, define 0)
		IFNDEF	BB_VRAM_A16_ADDR
BB_VRAM_A16_ADDR:	EQU	0
		ENDIF

; Advance compressed stream pointer past 8KB window boundary.
; Preserves AF, BC, DE. Sets HL = BB_WINDOW_START_H:00.
bb_next_bank:
		push	af
		push	bc
		ld	a,(BB_BANK_ADDR)
		inc	a
		ld	(BB_BANK_ADDR),a
		ld	bc,BB_BANK_REG
		ld	(bc),a
		pop	bc
		pop	af
		ld	h,BB_WINDOW_START_H
		ld	l,$00
		scf			; preserve sentinel carry for bitstream reload
		ret

		MACRO	BB_CHECK_BANK
		ld	a,h
		cp	BB_WINDOW_END_H
		call	nc,bb_next_bank
		ENDM

; Read byte from compressed stream into A, advance HL, handle bank crossing.
; Clobbers flags only.
		MACRO	BB_READ_BYTE_A
		BB_CHECK_BANK
		ld	a,(hl)
		inc	hl
		ENDM

; Read byte from compressed stream into C, advance HL, handle bank crossing.
; Preserves A.
		MACRO	BB_READ_BYTE_C
		push	af
		BB_CHECK_BANK
		pop	af
		ld	c,(hl)
		inc	hl
		ENDM

		IFDEF	BITBUSTER_OPTIMIZE_SPEED
		MACRO	GET_BIT_FROM_BITSTREAM
		add	a,a
		jp	nz,1f
		BB_CHECK_BANK
		ld	a,(hl)
		inc	hl
		rla
1:
		ENDM
		ELSE
		MACRO	GET_BIT_FROM_BITSTREAM
		call	get_bit_from_bitstream
		ENDM

; get a bit from the bitstream
; carry if bit is set, nocarry if bit is clear
; preserves BC, DE, HL; updates A as bit buffer
get_bit_from_bitstream:
		add	a,a
		ret	nz
		BB_CHECK_BANK
		ld	a,(hl)
		inc	hl
		rla
		ret
		ENDIF

; Set VDP for VRAM write. DE = A0-A15, BB_VRAM_A16_ADDR bit 2 = A16.
set_vram_write:
		ld	c,BITBUSTER_VRAM_CMD_PORT
		ld	a,d
		rlca
		rlca
		and	$03
	IF BB_VRAM_A16_ADDR
		ld	b,a
		ld	a,(BB_VRAM_A16_ADDR)
		and	$04
		or	b
	ELSE
		; no A16
	ENDIF
		out	(c),a
		ld	a,$80+14
		out	(c),a
		ld	a,e
		out	(c),a
		ld	a,d
		and	$3F
		or	$40
		out	(c),a
		ret

; Set VDP for VRAM read. DE = A0-A15, BB_VRAM_A16_ADDR bit 2 = A16.
set_vram_read:
		ld	c,BITBUSTER_VRAM_CMD_PORT
		ld	a,d
		rlca
		rlca
		and	$03
	IF BB_VRAM_A16_ADDR
		ld	b,a
		ld	a,(BB_VRAM_A16_ADDR)
		and	$04
		or	b
	ENDIF
		out	(c),a
		ld	a,$80+14
		out	(c),a
		ld	a,e
		out	(c),a
		ld	a,d
		and	$3F
		out	(c),a
		ret

; write one byte from compressed stream to VRAM
		MACRO	WRITE_LITERAL_TO_VRAM
		ex	af,af'
		call	set_vram_write
		BB_CHECK_BANK
		ld	a,(hl)
		out	(BITBUSTER_VRAM_DATA_PORT),a
		inc	hl
		ex	af,af'
		inc	de
		ENDM

; Depack a block from banked compressed stream to VRAM.
; ENTRY: HL=compressed data pointer (banked window), DE=VRAM dest (A16 in BB_VRAM_A16_ADDR)
; EXIT:  HL=after compressed data, DE=after decompressed data
depack_block_raw:	EXPORT	bitbuster_vram_bank.depack_block_raw
		di
		call	set_vram_write
		ld	a,128

depack_loop:	GET_BIT_FROM_BITSTREAM
		jp	c,output_compressed
		WRITE_LITERAL_TO_VRAM
		IFDEF	BITBUSTER_OPTIMIZE_SPEED
		GET_BIT_FROM_BITSTREAM
		jp	c,output_compressed
		WRITE_LITERAL_TO_VRAM
		GET_BIT_FROM_BITSTREAM
		jp	c,output_compressed
		WRITE_LITERAL_TO_VRAM
		ENDIF
		jp	depack_loop

output_compressed:
		ld	bc,1
get_gamma_value:
		GET_BIT_FROM_BITSTREAM
		jr	nc,get_gamma_value_end
		GET_BIT_FROM_BITSTREAM
		rl	c
		rl	b
		jp	nc,get_gamma_value
		ei
		ret

get_gamma_value_end:
		ld	iyh,b
		ld	iyl,c

		push	af		; preserve bitstream
		BB_CHECK_BANK
		ld	c,(hl)
		inc	hl
		pop	af

		ld	b,0
		bit	7,c
		jr	z,output_match1

		GET_BIT_FROM_BITSTREAM
		rl	b
		GET_BIT_FROM_BITSTREAM
		rl	b
		GET_BIT_FROM_BITSTREAM
		rl	b
		GET_BIT_FROM_BITSTREAM

		jp	c,output_match2
		res	7,c
output_match1:	scf
output_match2:	push	hl

		ld	h,d
		ld	l,e
		sbc	hl,bc

		ld	b,iyh
		ld	c,iyl
		call	copy_match_vram

		pop	hl
		jp	depack_loop

copy_match_vram:
		push	af
		inc	bc
.copy_loop:
		push	bc
		ex	de,hl
		call	set_vram_read
		in	a,(BITBUSTER_VRAM_DATA_PORT)
		ex	af,af'
		ex	de,hl
		call	set_vram_write
		ex	af,af'
		out	(BITBUSTER_VRAM_DATA_PORT),a
		inc	hl
		inc	de
		pop	bc
		dec	bc
		ld	a,b
		or	c
		jr	nz,.copy_loop
		pop	af
		ret

		ENDMODULE
