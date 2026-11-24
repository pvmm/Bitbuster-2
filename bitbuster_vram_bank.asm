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
;	  BB_BANK_ADDR      - RAM byte holding current bank number
;	  BB_BANK_REG       - mapper register address (default $7000 for 8000-9FFF)
;	  BB_WINDOW_END_H   - high byte of first address past window (default $A0)
;	  BB_WINDOW_START_H - high byte of window start (default $80)
;	  BB_VRAM_A16_ADDR  - RAM byte, bit 2 = VRAM A16 (0 = disabled)
;	  BB_END_BANK_ADDR  - RAM byte: temporary end bank for depack_pck
;	  BB_END_HL_ADDR    - RAM word: temporary end HL for depack_pck
;
;	depack_pck: consumes standard PCK stream (count + len,len,payload...).
;	Returns HL=stream ptr, DE=VRAM end, A=blocks left. Restores HL to the
;	true block end to guard against bitstream overread at gamma overflow.
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

; Bank-aware BitBuster VRAM decompressor.
; Configured by BB_BANK_ADDR, BB_VRAM_A16_ADDR, BB_BANK_REG,
; BB_WINDOW_START_H, BB_WINDOW_END_H, BB_END_BANK_ADDR, BB_END_HL_ADDR.

		IFNDEF	BITBUSTER_VRAM_DATA_PORT
BITBUSTER_VRAM_DATA_PORT:	EQU	$98
		ENDIF
		IFNDEF	BITBUSTER_VRAM_CMD_PORT
BITBUSTER_VRAM_CMD_PORT:	EQU	$99
		ENDIF

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

get_bit_from_bitstream:
		add	a,a
		ret	nz
		BB_CHECK_BANK
		ld	a,(hl)
		inc	hl
		rla
		ret
		ENDIF

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

; Bank-aware depack: reads standard PCK stream (count + len,len,payload...)
; ENTRY: HL=stream ptr, DE=VRAM dest, A=0 start new / <>0 continue
; EXIT:  HL=decompressed size, BC=decompressed size, DE=end VRAM, A=blocks left
;        Stream pointer is left after last consumed block in (BB_END_HL_ADDR)/(BB_BANK_ADDR)
; Note: this implementation decompresses one block per call when A!=0 not supported
;       the same way as original; use depack_pck for full stream.
depack_pck:	EXPORT	bitbuster_vram_bank.depack_pck
		; A = 0: read count
		or	a
		jr	nz,.next_block
		BB_CHECK_BANK
		ld	a,(hl)
		inc	hl
.next_block:
		push	af		; blocks remaining (preserve across BB_CHECK_BANK)
		; read 2-byte block size
		BB_CHECK_BANK
		ld	c,(hl)
		inc	hl
		BB_CHECK_BANK
		ld	b,(hl)
		inc	hl
		; BC = compressed block size
		push	de		; VRAM dest start
		push	bc		; compressed size

		; compute end = HL + BC, handling bank wrap
		ld	a,(BB_BANK_ADDR)
		ld	(BB_END_BANK_ADDR),a
		push	hl
		add	hl,bc
		ld	a,h
		cp	BB_WINDOW_END_H
		jr	c,.end_ok
		; wrap: HL -= window_size, end_bank++
		sub	(BB_WINDOW_END_H - BB_WINDOW_START_H)
		ld	h,a
		ld	a,(BB_END_BANK_ADDR)
		inc	a
		ld	(BB_END_BANK_ADDR),a
.end_ok:
		ld	(BB_END_HL_ADDR),hl
		pop	hl		; HL = payload start

		call	depack_block_raw

		; restore stream pointer to true end of block
		ld	a,(BB_END_BANK_ADDR)
		ld	(BB_BANK_ADDR),a
		ld	bc,BB_BANK_REG
		ld	(bc),a
		ld	hl,(BB_END_HL_ADDR)

		; HL = stream ptr, DE = VRAM end
		pop	bc		; discard compressed size
		pop	bc		; discard original VRAM dest
		pop	af		; blocks remaining
		dec	a
		ret

; Raw block depack (HL at compressed data, banked)
depack_block_raw:	EXPORT	bitbuster_vram_bank.depack_block_raw
		di
		call	set_vram_write
		ld	a,128

depack_loop:	GET_BIT_FROM_BITSTREAM
		jp	c,output_compressed
		WRITE_LITERAL_TO_VRAM
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

		push	af
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
