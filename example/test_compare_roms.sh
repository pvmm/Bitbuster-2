#!/usr/bin/env bash
set -euo pipefail

# Compare decompressed SCREEN 8 output of EXAMPLE_ROM.ROM and EXAMPLE_VRAM.ROM.
# Requires: openmsx, python3 with Pillow (PIL).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d /tmp/opencode/bitbuster-test.XXXXXX)"
REF_PNG="$TMP_DIR/ref.png"
VRAM_PNG="$TMP_DIR/vram.png"
REF_TCL="$TMP_DIR/ref.tcl"
VRAM_TCL="$TMP_DIR/vram.tcl"

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
after time 6 { screenshot $REF_PNG; exit }
TCL

cat > "$VRAM_TCL" <<TCL
after time 6 { screenshot $VRAM_PNG; exit }
TCL

echo "Capturing EXAMPLE_ROM.ROM..."
timeout 30 openmsx -cart "$SCRIPT_DIR/EXAMPLE_ROM.ROM" -script "$REF_TCL" >/dev/null

echo "Capturing EXAMPLE_VRAM.ROM..."
timeout 30 openmsx -cart "$SCRIPT_DIR/EXAMPLE_VRAM.ROM" -script "$VRAM_TCL" >/dev/null

python3 - "$REF_PNG" "$VRAM_PNG" <<'PY'
import sys
from PIL import Image, ImageChops, ImageStat

ref_path, vram_path = sys.argv[1], sys.argv[2]
ref = Image.open(ref_path).convert("RGB")
vram = Image.open(vram_path).convert("RGB")

if ref.size != vram.size:
    print(f"FAIL: size mismatch {ref.size} != {vram.size}")
    sys.exit(1)

diff = ImageChops.difference(ref, vram)
stat = ImageStat.Stat(diff)
mean = sum(stat.mean) / 3.0
max_diff = max(channel[1] for channel in stat.extrema)

if mean == 0.0 and max_diff == 0:
    print("PASS: screenshots are identical")
    sys.exit(0)

diff_path = "/tmp/opencode/bitbuster-rom-diff.png"
diff.save(diff_path)
print(f"FAIL: mean diff={mean:.4f}, max diff={max_diff}")
print(f"Diff image saved to {diff_path}")
sys.exit(1)
PY
