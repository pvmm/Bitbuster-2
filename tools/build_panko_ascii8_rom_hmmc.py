#!/usr/bin/env python3
"""Build an ASCII8/ASCII16 MegaROM for MSX2 that displays a 512x370 interlaced
SCREEN 7 image by decompressing BitBuster-compressed field data to a RAM buffer
and transferring each decompressed block to VRAM using V9938 HMMC.

Uses bitbuster_bank.asm (bank-aware RAM decompressor). Compressed payloads are
packed back-to-back across banks as a continuous stream, with no per-block padding.

Inputs (defaults relative to this repo layout):
  example/panko.pc0   - even field, BitBuster -b 8192
  example/panko.pc1   - odd field,  BitBuster -b 8192
  example/panko.PAL   - optional 7-byte-header + 32-byte V9938 palette
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PC0 = ROOT / "example" / "panko.pc0"
DEFAULT_PC1 = ROOT / "example" / "panko.pc1"
DEFAULT_PAL = ROOT / "example" / "panko.PAL"
DEFAULT_OUT = ROOT / "panko_ascii8_hmmc.rom"
SJASMPLUS = Path(os.environ.get("SJASMPLUS", "/home/pedro/bin/sjasmplus"))

DEFAULT_PALETTE = bytes([
    0x00, 0x00, 0x10, 0x00, 0x10, 0x01, 0x11, 0x01,
    0x20, 0x01, 0x21, 0x01, 0x23, 0x02, 0x24, 0x02,
    0x31, 0x01, 0x31, 0x02, 0x32, 0x02, 0x41, 0x02,
    0x05, 0x02, 0x52, 0x03, 0x60, 0x02, 0x62, 0x03,
])

MAPPER_CONFIG = {
    "ascii8": {
        "bank_size": 8192,
        "bank_reg": 0x7000,
        "window_start_h": 0x80,
        "window_end_h": 0xA0,
        "mapper_init": """        ; ASCII8: 6000->4000,6800->6000,7000->8000,7800->A000
        xor a
        ld ($6000),a
        inc a
        ld ($6800),a
        inc a
        ld ($7000),a
        inc a
        ld ($7800),a""",
    },
    "ascii16": {
        "bank_size": 16384,
        "bank_reg": 0x7000,
        "window_start_h": 0x80,
        "window_end_h": 0xC0,
        "mapper_init": """        ; ASCII16: 6000->4000-7FFF, 7000/77FF->8000-BFFF
        xor a
        ld ($6000),a
        inc a
        ld ($7000),a
        ld ($77FF),a""",
    },
}

ASM_TEMPLATE = r"""        OUTPUT "{outbin}"
        ORG $4000

; Mapper config
BB_BANK_REG:      equ ${bank_reg:04X}
BB_WINDOW_START_H: equ ${window_start_h:02X}
BB_WINDOW_END_H:   equ ${window_end_h:02X}
DATA_FIRST_BANK:  equ 1
BLOCK_BUFFER:     equ $D000  ; 8KB RAM buffer for one decompressed block

CHGMOD:         equ $005F
ENASLT:         equ $0024
EXPTBL:         equ $FCC1
HIMEM:          equ $FC4A
PPI_A:          equ $A8

; RAM variables
BB_BANK_ADDR:     equ $C000
BB_END_BANK_ADDR: equ $C001
BB_END_HL_ADDR:   equ $C002  ; 2 bytes
VRAM_DY:          equ $C004  ; 2 bytes, current VRAM Y for HMMC

        db "AB"
        dw init
        dw 0,0,0,0,0,0

init:
        di
        ld sp,(HIMEM)

        ; Map page 2 to same slot/subslot as page 1 (ROM slot)
        in a,(PPI_A)
        rrca
        rrca
        and %00000011
        ld c,a
        ld hl,EXPTBL
        add a,l
        ld l,a
        ld a,(hl)
        and $80
        or c
        ld c,a
        inc l
        inc l
        inc l
        inc l
        ld a,(hl)
        and %00001100
        or c
        ld h,$80
        call ENASLT

{mapper_init}

        ; SCREEN 7
        ld a,7
        call CHGMOD

        ; R#8 = VR|TP|SPD
        di
        ld a,$2A
        out ($99),a
        ld a,$88
        out ($99),a
        ei

        call set_palette

        ; Black border and black background (palette index 1)
        di
        xor a
        out ($99),a
        ld a,$87
        out ($99),a
        ld a,$01
        out ($99),a
        ld a,$90
        out ($99),a
        xor a
        out ($9A),a
        out ($9A),a
        ei

        ; Initialize bank-aware compressed stream
        ld a,DATA_FIRST_BANK
        ld (BB_BANK_ADDR),a
        ld (BB_BANK_REG),a
        ld hl,BB_WINDOW_START_H * 256

        ; Even field (pc0) -> VRAM page 0 (DY=0)
        xor a
        ld (VRAM_DY),a
        ld (VRAM_DY+1),a
        xor a               ; start new PCK stream
        call depack_pck_to_vram_hmmc

        ; Odd field (pc1) -> VRAM page 1 (DY=256)
        xor a
        ld (VRAM_DY),a
        ld a,1
        ld (VRAM_DY+1),a
        xor a               ; start new PCK stream
        call depack_pck_to_vram_hmmc

        ; Enable SCREEN 7 interlace: R#9 = LN|IL|EO
        di
        ld a,$8C
        out ($99),a
        ld a,$89
        out ($99),a
        ei

.loop:
        jr .loop

set_palette:
        di
        xor a
        out ($99),a
        ld a,$90
        out ($99),a
        ld hl,palette_data
        ld c,$9A
        ld b,32
        otir
        ei
        ret
"""
ASM_TEMPLATE += r"""
; Decompress all blocks in a PCK stream to RAM buffer, then HMMC to VRAM.
; ENTRY: HL=stream ptr, A=0 new PCK, VRAM_DY set to destination Y base
; EXIT:  HL=stream ptr after PCK
depack_pck_to_vram_hmmc:
        ; read block count
        ld a,h
        cp BB_WINDOW_END_H
        call nc,bitbuster_bank.bb_next_bank
        ld a,(hl)
        inc hl
.block_loop:
        push af             ; blocks remaining

        ; read 2-byte compressed block size
        ld a,h
        cp BB_WINDOW_END_H
        call nc,bitbuster_bank.bb_next_bank
        ld c,(hl)
        inc hl
        ld a,h
        cp BB_WINDOW_END_H
        call nc,bitbuster_bank.bb_next_bank
        ld b,(hl)
        inc hl
        push bc             ; compressed size

        ; compute true end of compressed block (handles bank wrap)
        ld a,(BB_BANK_ADDR)
        ld (BB_END_BANK_ADDR),a
        push hl
        add hl,bc
        ld a,h
        cp BB_WINDOW_END_H
        jr c,.end_ok
        sub (BB_WINDOW_END_H - BB_WINDOW_START_H)
        ld h,a
        ld a,(BB_END_BANK_ADDR)
        inc a
        ld (BB_END_BANK_ADDR),a
.end_ok:
        ld (BB_END_HL_ADDR),hl
        pop hl              ; HL = payload start

        ; decompress to RAM buffer
        ld de,BLOCK_BUFFER
        call bitbuster_bank.depack_block_raw

        ; HL = after compressed payload, DE = end of decompressed in buffer
        ; compute decompressed size = DE - BLOCK_BUFFER
        push hl
        ld hl,BLOCK_BUFFER
        ex de,hl
        or a
        sbc hl,de           ; HL = decompressed size in bytes
        ld b,h
        ld c,l              ; BC = bytes

        ; NY = bytes / 256 (SCREEN 7: 256 bytes per line)
        ; BC is multiple of 256 for 8192-byte blocks; last may be smaller.
        ld a,b
        or a
        jr z,.skip_hmmc     ; 0 bytes? skip
        ld e,a              ; E = NY (lines)
        ld d,0              ; D not used

        ; HMMC: DX=0, DY=VRAM_DY, NX=512, NY=E
        ld hl,(VRAM_DY)
        push hl             ; save DY for increment
        call hmmc_block     ; transfer BLOCK_BUFFER, NY=E, DY=HL

        pop hl              ; DY
        ; DY += NY
        ld a,l
        add a,e             ; NY <= 255 here (max 32 for 8KB)
        ld l,a
        jr nc,.dy_ok
        inc h
.dy_ok:
        ld (VRAM_DY),hl

.skip_hmmc:
        pop hl              ; restore stream pointer (after payload)

        ; restore stream pointer to true block end
        ld a,(BB_END_BANK_ADDR)
        ld (BB_BANK_ADDR),a
        ld bc,BB_BANK_REG
        ld (bc),a
        ld hl,(BB_END_HL_ADDR)

        pop bc              ; discard compressed size
        pop af              ; blocks remaining
        dec a
        jr nz,.block_loop
        ret
"""
ASM_TEMPLATE += r"""
; HMMC transfer: copy RAM buffer to VRAM as 512xNY rectangle.
; ENTRY: HL=DY (VRAM Y), E=NY (lines), source=BLOCK_BUFFER
; DESTROYS: AF,BC,DE,HL
hmmc_block:
        ld d,e              ; D = NY
        push hl             ; save DY

        call vdp_wait_ce

        ld a,36
        out ($99),a
        ld a,$80+17
        out ($99),a

        ld c,$9B
        xor a               ; DX low
        out (c),a
        out (c),a           ; DX high
        pop hl              ; DY
        out (c),l           ; DY low
        out (c),h           ; DY high
        xor a               ; NX low
        out (c),a
        ld a,2              ; NX high (512)
        out (c),a
        out (c),d           ; NY low
        xor a
        out (c),a           ; NY high
        ld hl,BLOCK_BUFFER
        ld a,(hl)           ; CLR = first byte
        out (c),a
        xor a               ; ARG
        out (c),a
        ld a,$F0            ; CMD = HMMC
        out (c),a

        ; Send remaining NY*256-1 bytes
        inc hl
        ld e,d              ; E = NY lines
        ld b,$FF            ; 255 bytes in first partial line

        ; Set S#2 for status, keep R#17 pointing to R#44 (no auto-increment)
        ld a,44+$80
        out ($99),a
        ld a,$80+17
        out ($99),a
        ld a,2
        out ($99),a
        ld a,$80+15
        out ($99),a
        ld c,$9B

.hmmc_wait:
        in a,($99)          ; S#2: bit 7=TR, bit 0=CE
        bit 7,a
        jr z,.hmmc_wait     ; TR==0, not ready
        outi                ; send byte to R#44
        jp nz,.hmmc_wait
        dec e
        jr z,.hmmc_done
        ld b,0              ; 256
        jp .hmmc_wait

.hmmc_done:
        ld e,d              ; restore NY for caller
        ; Wait for command to finish
.ce_wait:
        in a,($99)
        rra
        jr c,.ce_wait
        xor a
        out ($99),a
        ld a,$80+15
        out ($99),a
        ei
        ret

; Wait for VDP command engine not busy (S#2 CE bit 0 = 0). Returns with DI.
vdp_wait_ce:
        di
        ld a,2
        out ($99),a
        ld a,$80+15
        out ($99),a
.ce_loop:
        in a,($99)
        rra
        jr c,.ce_loop
        xor a
        out ($99),a
        ld a,$80+15
        out ($99),a
        ret
"""
ASM_TEMPLATE += r"""
palette_data:
{palette_db}

        INCLUDE "bitbuster_bank.inc"
"""


def parse_pck(path: Path) -> list[bytes]:
    data = path.read_bytes()
    if len(data) < 1:
        raise ValueError(f"{path}: empty file")
    count = data[0]
    off = 1
    blocks = []
    for i in range(count):
        if off + 2 > len(data):
            raise ValueError(f"{path}: truncated block header {i}")
        blen = data[off] | (data[off + 1] << 8)
        off += 2
        if off + blen > len(data):
            raise ValueError(f"{path}: truncated block {i}")
        blocks.append(data[off:off + blen])
        off += blen
    if off != len(data):
        raise ValueError(f"{path}: trailing data ({len(data) - off} bytes)")
    return blocks


def load_palette(path: Path) -> bytes:
    if not path.exists():
        return DEFAULT_PALETTE
    data = path.read_bytes()
    if len(data) == 32:
        return data
    if len(data) >= 39:
        return data[7:39]
    raise ValueError(f"{path}: unsupported palette size {len(data)}")


def format_db(data: bytes, per_line: int = 16) -> str:
    lines = []
    for i in range(0, len(data), per_line):
        chunk = data[i:i + per_line]
        lines.append("        db " + ",".join(f"${b:02X}" for b in chunk))
    return "\n".join(lines)


def assemble_bank0(asm_source: str, tmpdir: Path) -> bytes:
    asm_path = tmpdir / "bank0.asm"
    inc_path = tmpdir / "bitbuster_bank.inc"
    out_path = tmpdir / "bank0.bin"
    asm_path.write_text(asm_source, encoding="utf-8")
    inc_path.write_text((ROOT / "bitbuster_bank.asm").read_text(encoding="utf-8"), encoding="utf-8")
    cmd = [str(SJASMPLUS), "--raw=" + str(out_path), str(asm_path)]
    proc = subprocess.run(cmd, cwd=tmpdir, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stdout.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise RuntimeError("sjasmplus failed")
    if not out_path.exists():
        raise RuntimeError("sjasmplus did not produce bank0.bin")
    return out_path.read_bytes()


def pack_stream(blocks: list[bytes], bank_size: int) -> list[bytes]:
    stream = b"".join(blocks)
    banks = []
    for i in range(0, len(stream), bank_size):
        chunk = stream[i:i + bank_size]
        banks.append(chunk.ljust(bank_size, b"\xFF"))
    if not banks:
        banks = [b"\xFF" * bank_size]
    return banks


def build_rom(pc0: Path, pc1: Path, pal: Path, out: Path, mapper: str) -> None:
    cfg = MAPPER_CONFIG[mapper]
    bank_size = cfg["bank_size"]
    blocks0 = parse_pck(pc0)
    blocks1 = parse_pck(pc1)
    palette = load_palette(pal)

    with tempfile.TemporaryDirectory(dir="/tmp/opencode", prefix="panko-hmmc-") as td:
        tmpdir = Path(td)
        asm = ASM_TEMPLATE.format(
            outbin="bank0.bin",
            bank_reg=cfg["bank_reg"],
            window_start_h=cfg["window_start_h"],
            window_end_h=cfg["window_end_h"],
            mapper_init=cfg["mapper_init"],
            palette_db=format_db(palette),
        )
        bank0 = assemble_bank0(asm, tmpdir)

    if len(bank0) > bank_size:
        raise RuntimeError(f"bank 0 code too large: {len(bank0)} bytes (max {bank_size})")
    bank0 = bank0.ljust(bank_size, b"\xFF")

    stream = pc0.read_bytes() + pc1.read_bytes()
    data_banks = pack_stream([stream], bank_size)
    rom = bytearray(bank0)
    for b in data_banks:
        rom.extend(b)

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(rom)

    last_slack = bank_size - (len(stream) % bank_size or bank_size)
    print(f"ROM: {out}")
    print(f"  mapper: {mapper} ({bank_size // 1024}KB banks)")
    print(f"  size: {len(rom)} bytes ({len(rom) // bank_size} banks)")
    print(f"  pc0: {pc0} ({len(blocks0)} blocks, {sum(len(b) for b in blocks0)} payload bytes)")
    print(f"  pc1: {pc1} ({len(blocks1)} blocks, {sum(len(b) for b in blocks1)} payload bytes)")
    print(f"  stream: {len(stream)} bytes in {len(data_banks)} data banks, last-bank slack {last_slack} bytes")
    print(f"  palette: {pal if pal.exists() else 'DEFAULT'}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pc0", type=Path, default=DEFAULT_PC0, help="Even field .pc0")
    ap.add_argument("--pc1", type=Path, default=DEFAULT_PC1, help="Odd field .pc1")
    ap.add_argument("--pal", type=Path, default=DEFAULT_PAL, help="Palette file")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help="Output ROM")
    ap.add_argument("--mapper", choices=sorted(MAPPER_CONFIG.keys()), default="ascii8",
                    help="Mapper/bank size: ascii8=8KB, ascii16=16KB")
    args = ap.parse_args()

    for p in [args.pc0, args.pc1]:
        if not p.exists():
            print(f"missing input: {p}", file=sys.stderr)
            return 1
    build_rom(args.pc0, args.pc1, args.pal, args.out, args.mapper)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
