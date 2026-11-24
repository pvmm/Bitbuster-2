#!/usr/bin/env bash
set -euo pipefail

# Compare decompressed SCREEN 8 VRAM output of EXAMPLE_ROM.ROM and EXAMPLE_VRAM.ROM.
# Requires: openmsx, python3.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d /tmp/opencode/bitbuster-test.XXXXXX)"
REF_BIN="$TMP_DIR/ref.bin"
VRAM_BIN="$TMP_DIR/vram.bin"
REF_TCL="$TMP_DIR/ref.tcl"
VRAM_TCL="$TMP_DIR/vram.tcl"
MACHINE="${OPENMSX_MACHINE:-C-BIOS_MSX2+}"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for cmd in openmsx python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

for rom in "$SCRIPT_DIR/EXAMPLE_ROM.ROM" "$SCRIPT_DIR/EXAMPLE_VRAM.ROM"; do
  if [ ! -f "$rom" ]; then
    echo "Missing ROM: $rom" >&2
    echo "Assemble examples first (e.g. sjasmplus example_rom.asm)." >&2
    exit 1
  fi
done

cat > "$REF_TCL" <<TCL
after realtime 8 { save_debuggable VRAM $REF_BIN; exit }
TCL

cat > "$VRAM_TCL" <<TCL
after realtime 8 { save_debuggable VRAM $VRAM_BIN; exit }
TCL

echo "Capturing EXAMPLE_ROM.ROM..."
timeout 30 openmsx -machine "$MACHINE" -cart "$SCRIPT_DIR/EXAMPLE_ROM.ROM" -script "$REF_TCL" >/dev/null

echo "Capturing EXAMPLE_VRAM.ROM..."
timeout 30 openmsx -machine "$MACHINE" -cart "$SCRIPT_DIR/EXAMPLE_VRAM.ROM" -script "$VRAM_TCL" >/dev/null

python3 - "$REF_BIN" "$VRAM_BIN" <<'PY'
import sys

ref_path, vram_path = sys.argv[1], sys.argv[2]
ref = open(ref_path, "rb").read(54272)
vram = open(vram_path, "rb").read(54272)

if ref == vram:
    print("PASS: VRAM dumps are identical (54272 bytes)")
    sys.exit(0)

diffs = [i for i in range(len(ref)) if ref[i] != vram[i]]
print(f"FAIL: {len(diffs)} differing bytes")
print(f"First diff at 0x{diffs[0]:04X}: ref=0x{ref[diffs[0]]:02X} got=0x{vram[diffs[0]]:02X}")
print(f"Last diff at 0x{diffs[-1]:04X}")
sys.exit(1)
PY
