;	Copyright (c) 2003-2004,2022 Arjan Bakker
;	VRAM-direct variant for MSX2 (V9938/V9958) - writes decompressed data
;	directly to VRAM, supporting addresses above 16KB.
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

		MODULE	bitbuster_vram

; File: bitbuster_vram
;
;	Variant of the BitBuster 2 decompressor that writes directly to VRAM.
;	Unlike bitbuster.asm, this version does not decompress to RAM first.
;
;	NOTES:
;	- Intended for MSX2/2+/turboR with V9938/V9958 VDP.
;	- Supports VRAM destination addresses above 16KB (uses VDP register 14).
;	- Match copies read back from VRAM, so decompression is slower than the
;	  RAM variant, but no intermediate RAM buffer is needed.
;	- VDP data/command ports default to $98/$99. Override by defining
;	  BITBUSTER_VRAM_DATA_PORT and/or BITBUSTER_VRAM_CMD_PORT before including.
;
; FUNCTION NAMES:
;	The functions <depack> and <depack_block> are MODULE local, which means you
;	have to add the prefix "bitbuster_vram." to its name.
;	If you define <MAKE_BITBUSTER_GLOBAL> then these functions will be
;	available without the "bitbuster_vram." prefix as well.
;
; DEFINE:	MAKE_BITBUSTER_GLOBAL
;	Defining this will make public functions available without the module prefix.
;
; DEFINE:	BITBUSTER_OPTIMIZE_SPEED
;	Defining this will optimize for speed at the cost of bigger code.

		IFNDEF	BITBUSTER_VRAM_DATA_PORT
BITBUSTER_VRAM_DATA_PORT:	EQU	$98
		ENDIF

		IFNDEF	BITBUSTER_VRAM_CMD_PORT
BITBUSTER_VRAM_CMD_PORT:	EQU	$99
		ENDIF


		IFDEF	BITBUSTER_OPTIMIZE_SPEED
; macro to get a bit from the bitstream
; carry if bit is set, nocarry if bit is clear
		MACRO	GET_BIT_FROM_BITSTREAM
		add	a,a			; shift out new bit
		jp nz,.done		; if remaining value isn't zero, we're done

		ld a,(hl)		; get 8 bits from bitstream
		inc	hl			; increase source data address

		rla				; (bit 0 will be set!!!!)
.done:
		ENDM

		ELSE

; macro to get a bit from the bitstream
; carry if bit is set, nocarry if bit is clear
		MACRO	GET_BIT_FROM_BITSTREAM
		call	get_bit_from_bitstream
		ENDM

; get a bit from the bitstream
; carry if bit is set, nocarry if bit is clear
get_bit_from_bitstream:
		add	a,a		; shift out new bit
		ret	nz		; if remaining value isn't zero, we're done

		ld a,(hl)	; get 8 bits from bitstream
		inc hl		; increase source data address

		rla         ;(bit 0 will be set!!!!)
		ret

		ENDIF		; IFNDEF BITBUSTER_OPTIMIZE_SPEED


; FUNCTION:	set_vram_write
;	Set VDP address for sequential VRAM writes.
;
; ENTRY:
;	DE - VRAM address
;
; MODIFIES:
;	$AF, C#
set_vram_write:
		ld	c,BITBUSTER_VRAM_CMD_PORT
		ld	a,d
		rlca
		rlca
		and	$03			; A14-A15
		out	(c),a
		ld	a,$80+14
		out	(c),a			; set VDP reg 14 for high VRAM address bits
		ld	a,e
		out	(c),a
		ld	a,d
		and	$3F
		or	$40
		out	(c),a			; set VRAM address A0-A13, write mode
		ret


; FUNCTION:	set_vram_read
;	Set VDP address for sequential VRAM reads.
;
; ENTRY:
;	DE - VRAM address
;
; MODIFIES:
;	$AF, C#
set_vram_read:
		ld	c,BITBUSTER_VRAM_CMD_PORT
		ld	a,d
		rlca
		rlca
		and	$03			; A14-A15
		out	(c),a
		ld	a,$80+14
		out	(c),a			; set VDP reg 14 for high VRAM address bits
		ld	a,e
		out	(c),a
		ld	a,d
		and	$3F
		out	(c),a			; set VRAM address A0-A13, read mode
		ret


; write one byte from compressed stream to VRAM
; ENTRY: HL = compressed data pointer, DE = VRAM destination
; EXIT:  HL++, DE++, A = byte written, VDP write pointer advanced
; MODIFIES: $AF, HL, DE#
		MACRO	WRITE_LITERAL_TO_VRAM
		ex	af,af'
		call	set_vram_write
		ld	a,(hl)
		out	(BITBUSTER_VRAM_DATA_PORT),a
		ex	af,af'
		inc	hl
		inc	de
		ENDM


; FUNCTION:	depack
;	Depack a blob of data that was packed with Bitbuster directly to VRAM.
;
; ENTRY:
;	HL - Address of packed data
;	DE - VRAM address to depack to
;	A  - Start decompressing new data (0) or continue decompressing (<>0)
;
; EXIT:
;	HL - Size of depacked data
;	A  - Number of blocks left to decompress
;	FZ - Last block has been decompressed
;	FNZ- Last block hasn't been decompressed
;
; MODIFIES:
;	$AF, BC, DE, HL#
;
depack:		EXPORT	bitbuster_vram.depack
		IFDEF	MAKE_BITBUSTER_GLOBAL
@depack:	EXPORT	depack
		ENDIF

		or	a
		jr	nz,depack_next_block	; continue depacking a block if more blocks left

		ld	a,(hl)		; get the number of blocks

		inc	hl			; move to size of first block

depack_next_block:
		inc	hl
		inc	hl          	; move over block size

		push af				; push number of blocks
		push de				; push destination VRAM address

		call depack_block	; decompress the block

		ex de,hl			; DE -> pointer to next block, HL -> pointer to first byte after decompressed data
		pop bc				; pop the original destination VRAM address
		or a				; clear carry
		sbc hl,bc			; calculate length of decompressed data
		ld b,h
		ld c,l				; put it in BC
		ex de,hl			; HL -> pointer to next block

		pop af				; pop number of blocks
		dec a				; one less to decompress
		ret


; FUNCTION:	depack_block
;	Depack raw Bitbuster data directly to VRAM.
;
; ENTRY:
;	HL - Address of packed data
;	DE - VRAM address to depack to
;
; EXIT:
;	HL - Address of first byte after compressed data
;	DE - VRAM address of first byte after decompressed data
;
; MODIFIES:
;	$AF, BC, BC', DE, DE', HL, HL'#
;
depack_block:	EXPORT	bitbuster_vram.depack_block
		IFDEF	MAKE_BITBUSTER_GLOBAL
@depack_block:	EXPORT	depack_block
		ENDIF

		di				; disable interrupts during VDP access
		call	set_vram_write		; set initial VRAM write address
		ld	a,128

depack_loop:	GET_BIT_FROM_BITSTREAM		; get compression type bit
		jp	c,output_compressed	; if set, we got lz77 compression
		WRITE_LITERAL_TO_VRAM		; copy literal byte to VRAM

		IFDEF	BITBUSTER_OPTIMIZE_SPEED
		GET_BIT_FROM_BITSTREAM		; get compression type bit
		jp	c,output_compressed	; if set, we got lz77 compression
		WRITE_LITERAL_TO_VRAM		; copy literal byte to VRAM
		GET_BIT_FROM_BITSTREAM		; get compression type bit
		jp	c,output_compressed	; if set, we got lz77 compression
		WRITE_LITERAL_TO_VRAM		; copy literal byte to VRAM
		ENDIF

		jp	depack_loop


;handle compressed data
output_compressed:
; calculate length value
		ld	bc,1
get_gamma_value:
		GET_BIT_FROM_BITSTREAM   	; get more bits
		jr 	nc,get_gamma_value_end
		GET_BIT_FROM_BITSTREAM   	; get next bit of value from bitstream
		rl	c
		rl	b
		jp 	nc,get_gamma_value  	; repeat unless overflow occurred (=end of block marker)
		ei
		ret

get_gamma_value_end:
		ld iyh,b
		ld iyl,c

		ld	c,(hl)			; get lowest 7 bits of offset, plus offset extension bit
		inc	hl			; to next byte in compressed data

		ld	b,0
		bit	7,c
		jr	z,output_match1		; no need to get extra bits if carry not set

		GET_BIT_FROM_BITSTREAM		; get offset bit 10
		rl	b
		GET_BIT_FROM_BITSTREAM		; get offset bit 9
		rl	b
		GET_BIT_FROM_BITSTREAM		; get offset bit 8
		rl	b
		GET_BIT_FROM_BITSTREAM		; get offset bit 7

		jp	c,output_match2		; since extension mark already makes bit 7 set
		res	7,c			; only clear it if the bit should be cleared
output_match1:	scf
output_match2:	push	hl			; address compressed data on stack

		ld	h,d
		ld	l,e			; destination VRAM address in HL...
		sbc	hl,bc		; calculate source VRAM address, keep CF in mind!

		ld b,iyh
		ld c,iyl

		call	copy_match_vram		; copy BC+1 bytes from VRAM source HL to VRAM dest DE

		pop	hl			; address compressed data back from stack

		IFDEF	BITBUSTER_OPTIMIZE_SPEED
		GET_BIT_FROM_BITSTREAM		; get compression type bit
		jp	c,output_compressed	; if set, we got lz77 compression
		WRITE_LITERAL_TO_VRAM		; copy literal byte to VRAM
		GET_BIT_FROM_BITSTREAM		; get compression type bit
		jp	c,output_compressed	; if set, we got lz77 compression
		WRITE_LITERAL_TO_VRAM		; copy literal byte to VRAM
		ENDIF

		jp	depack_loop


; FUNCTION:	copy_match_vram
;	Copy a match from VRAM to VRAM. Emulates LDIR+LDI behavior.
;
; ENTRY:
;	HL - Source VRAM address
;	DE - Destination VRAM address
;	BC - Length-1 (LDIR copies BC bytes, then one extra byte is copied)
;
; EXIT:
;	HL - HL + BC + 1
;	DE - DE + BC + 1
;	BC - 0
;	VDP write address set to DE (ready for sequential literal writes)
;
; MODIFIES:
;	BC, DE, HL, AF'#
;
copy_match_vram:
		push	af			; preserve bitstream buffer
		inc	bc			; ldir copies BC, then ldi copies 1 more => BC+1 total
.copy_loop:
		push	bc

		; read byte from VRAM source
		ex	de,hl			; DE = source, HL = dest
		call	set_vram_read
		in	a,(BITBUSTER_VRAM_DATA_PORT)
		ex	af,af'			; save byte

		; write byte to VRAM destination
		ex	de,hl			; DE = dest, HL = source
		call	set_vram_write
		ex	af,af'
		out	(BITBUSTER_VRAM_DATA_PORT),a

		inc	hl			; next source
		inc	de			; next destination

		pop	bc
		dec	bc
		ld	a,b
		or	c
		jr	nz,.copy_loop
		pop	af			; restore bitstream buffer
		ret

		ENDMODULE
