#!/usr/bin/env python3
"""Build an ASCII8/ASCII16 MegaROM for MSX2 that displays a 512x370 interlaced
SCREEN 7 image by decompressing BitBuster-compressed field data.

Uses a bank-aware BitBuster VRAM decompressor: compressed payloads are packed
back-to-back across banks as a continuous stream, with no per-block padding.
The depacker switches mapper banks when the source pointer crosses the mapped
window.

Inputs (defaults relative to this script / repo layout):
  panko.pc0   - even field, BitBuster -b 8192
  panko.pc1   - odd field,  BitBuster -b 8192
  panko.PAL   - optional 7-byte-header + 32-byte V9938 palette
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
DEFAULT_OUT = ROOT / "panko_ascii8.rom"
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

CHGMOD:         equ $005F
ENASLT:         equ $0024
EXPTBL:         equ $FCC1
HIMEM:          equ $FC4A
PPI_A:          equ $A8

; RAM variables
BB_BANK_ADDR:     equ $C000
BB_VRAM_A16_ADDR: equ $C001
BB_END_BANK_ADDR: equ $C002
BB_END_HL_ADDR:   equ $C003  ; 2 bytes

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

        ; Even field (pc0) -> VRAM 0x00000
        xor a
        ld (BB_VRAM_A16_ADDR),a
        ld de,$0000
        xor a               ; start new PCK stream
        call depack_pck_stream

        ; Odd field (pc1) -> VRAM 0x10000
        ld a,$04
        ld (BB_VRAM_A16_ADDR),a
        ld de,$0000
        xor a               ; start new PCK stream
        call depack_pck_stream

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

; Decompress all blocks in a PCK stream.
; ENTRY: HL=stream ptr, DE=VRAM dest, A=0, BB_*_ADDR set
; EXIT:  HL=stream ptr after PCK, DE=VRAM end
depack_pck_stream:
        call bitbuster_vram_bank.depack_pck
        jr nz,depack_pck_stream
        ret

palette_data:
{palette_db}

        INCLUDE "bitbuster_vram_bank.inc"
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
    inc_path = tmpdir / "bitbuster_vram_bank.inc"
    out_path = tmpdir / "bank0.bin"
    asm_path.write_text(asm_source, encoding="utf-8")
    # Use the canonical bank-aware depacker from repo root.
    inc_path.write_text((ROOT / "bitbuster_vram_bank.asm").read_text(encoding="utf-8"), encoding="utf-8")
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

    with tempfile.TemporaryDirectory(dir="/tmp/opencode", prefix="panko-rom-") as td:
        tmpdir = Path(td)
        asm = ASM_TEMPLATE.format(
            outbin="bank0.bin",
            bank_reg=cfg["bank_reg"],
            window_start_h=cfg["window_start_h"],
            window_end_h=cfg["window_end_h"],
            mapper_init=cfg["mapper_init"],
            pc0_count=len(blocks0),
            pc1_count=len(blocks1),
            palette_db=format_db(palette),
        )
        bank0 = assemble_bank0(asm, tmpdir)

    if len(bank0) > bank_size:
        raise RuntimeError(f"bank 0 code too large: {len(bank0)} bytes (max {bank_size})")
    bank0 = bank0.ljust(bank_size, b"\xFF")

    # Continuous stream: full PCK files back-to-back (count+sizes+payloads)
    stream = pc0.read_bytes() + pc1.read_bytes()
    data_banks = pack_stream([stream], bank_size)  # pack_stream joins, so wrap as single chunk
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
