# AGENTS.md

Notes for agents working in this repository.

## Project layout

- `compressor/BitBuster2/` - C++ BitBuster2 compressor/decompressor sources.
- `bitbuster2` - built Linux CLI binary (output in repo root by `Makefile`).
- `Makefile` - builds `bitbuster2` with `g++ -O2 -Wall -Wextra -std=c++11`.
- `bitbuster.asm` - original Z80 RAM decompressor (module `bitbuster`).
- `bitbuster_vram.asm` - Z80 V9938/V9958 VRAM-direct decompressor (module `bitbuster_vram`).
- `bitbuster_vram_bank.asm` - bank-aware VRAM BitBuster decompressor for continuous streams across 8KB/16KB mapper windows (module `bitbuster_vram_bank`).
- `example/` - MSX examples and ROM test script.
- `tools/build_panko_ascii8_rom.py` - generates ASCII8/ASCII16 SCREEN 7 interlaced panko ROM.

## Build / assemble

```bash
make clean && make          # builds ./bitbuster2
./bitbuster2 -h

/home/pedro/bin/sjasmplus example/example_rom.asm
/home/pedro/bin/sjasmplus example/example_vram.asm
python3 tools/build_panko_ascii8_rom.py
```

Linux portability fixes applied to compressor sources: added `#include <cstring>` to `compressor/BitBuster2/decompress.cpp` and `compressor/BitBuster2/OptionParser.cpp`.

## BitBuster formats

- **PCK/block stream**: `count` (1 byte), then for each block: `len_lo,len_hi` (2 bytes LE, compressed payload length) + compressed payload. Created by `bitbuster2 -b <blocksize>`.
- `bitbuster.depack` / `bitbuster_vram.depack`: HL=packed data, DE=dest, A=0 for new stream; returns HL=decompressed size, BC=size, DE=end, A=blocks remaining.
- `bitbuster.depack_block` / `bitbuster_vram.depack_block`: HL points at compressed data (after size), DE=dest; returns HL after compressed data, DE after decompressed data. End-of-block is signaled by gamma overflow (`ei; ret`).
- `tools/build_panko_ascii8_rom.py` uses a per-bank layout: raw compressed payload at bank offset 0 (no 2-byte size, no count), decompressed by `bitbuster_vram.depack_block_raw`.

## bitbuster_vram.asm (VRAM direct)

- Target: V9938/V9958 (MSX2+). Writes directly to VRAM via VDP ports; no RAM buffer.
- Default ports: data `$98`, cmd `$99`; override with `BITBUSTER_VRAM_DATA_PORT` / `BITBUSTER_VRAM_CMD_PORT`.
- Supports >16KB via VDP reg 14. **Reg 14 bits**: bit 0=A14, bit 1=A15, bit 2=A16 (128KB). Current shared `bitbuster_vram.asm` computes A14-A15 from D; it does **not** yet include runtime A16 support. The panko ASCII8 tool embeds an adapted copy that reads `VRAM_A16` RAM byte (bit 2) for 17-bit addresses.
- `di` during `depack_block`; `ei` only on end-of-block marker return. This avoids BIOS ISR corrupting VDP address latch.
- Bitstream `A` must be preserved around VDP I/O: use `ex af,af'` / push-pop AF as needed. Do not corrupt AF.
- Match copies are byte-by-byte VRAM read/write (`set_vram_read`, read $98, `set_vram_write`, write $98), so it is slow but RAM-free.
- Per-literal `set_vram_write` is robust against VDP pointer desync; it is slower. Use when debugging or when auto-increment assumptions are risky.
- `copy_match_vram` preserves BC across VDP port setup by pushing BC around byte copy; set_vram_read/write may clobber B/C.

## V9938 / SCREEN 7 notes

- SCREEN 7 (GRAPHIC 7): 512x212, 16 colors, 128KB VRAM. Page 0 at 0x00000, page 1 at 0x10000.
- Interlaced 512x370 (185 lines/field): even field 47360 bytes at 0x00000, odd field 47360 bytes at 0x10000. After decompression set R#9=`$8C` (LN|IL|EO).
- Typical setup: CHGMOD 7; R#8=`$2A` (VR|TP|SPD, no sprites, no transparent color 0); load palette through R#16 / port $9A; set R#7 backdrop as needed; decompress; enable interlace.
- Palette format in `panko.PAL`: 7-byte header + 32 bytes V9938 palette data, 2 bytes/color `[0RRR0BBB, 00000GGG]`.

## Bank-aware BitBuster / MegaROM (panko)

- `bitbuster_vram_bank.asm`: bank-aware VRAM decompressor. Reads compressed stream from a mapped window (`BB_BANK_REG`, `BB_WINDOW_START_H`, `BB_WINDOW_END_H`), switches banks via `bb_next_bank` on boundary, and supports 17-bit VRAM through `BB_VRAM_A16_ADDR`.
- **Critical**: `bb_next_bank` must return with carry set (`scf`) because get_bit reload depends on sentinel carry; BB_CHECK_BANK's `cp` destroys carry.
- `tools/build_panko_ascii8_rom.py` builds `panko_ascii8.rom` or `panko_ascii16.rom` from `../panko.pc0`, `../panko.pc1`, `../panko.PAL`.
- `--mapper ascii8` (default, 8KB banks, 8000-9FFF window) or `--mapper ascii16` (16KB banks, 8000-BFFF window).
- Continuous stream layout (option 1): full PCK files concatenated (count+len+payload), packed back-to-back across data banks with no per-block padding; only last data bank has slack.
- Runtime: set `BB_BANK_ADDR` to first data bank, HL=window start, call `depack_pck` loop for each PCK stream. `depack_pck` fixes HL to true block end (guards against bitstream overread).

## openmsx testing

- Use `-machine C-BIOS_MSX2+` for SCREEN 7 / V9938 tests. Headless scripts are sensitive to timing; prefer `after realtime` for dumps/screenshots.
- VRAM dump: `after realtime N { save_debuggable VRAM /tmp/opencode/x.bin; exit }`.
- Screenshots can be flaky in this environment; VRAM dumps are more reliable for automated checks.
- For VRAM comparisons, read full 131072-byte dump; SCREEN 7 page 1 is at `0x10000`.
- Example comparison script: `example/test_compare_roms.sh` (compares EXAMPLE_ROM.ROM vs EXAMPLE_VRAM.ROM by VRAM dump).

## Gotchas

- V9938 R#14 is A14-A16; setting only 2 bits breaks 128KB SCREEN 7 page 1 access.
- BIOS ISR can corrupt VDP address latch; keep `di` during VRAM decompression sequences.
- `depack` reports uncompressed size in BC/DE and HL points to next compressed block; caller must advance VRAM destination by returned size for multi-block streams.
- When debugging with openmsx Tcl watchpoints, `after time` is emulated time and watchpoint callbacks are slow; use `after realtime` for timeouts and native watchpoint conditions where possible.
