#!/usr/bin/env bash
# Extract the iOS arm64 NDI static lib + headers from the macOS SDK installer
# (Install_NDI_SDK_v6_Apple.pkg) into third_party/NDI/.
#
# Run once from the repo root:   bash third_party/NDI/extract_sdk.sh
# Requires: bsdtar (libarchive) and python3. The 225 MB .pkg stays gitignored;
# this vendors only the ~31 MB gzipped arm64 lib + the C headers.
set -euo pipefail

# Make conda-provided tools (bsdtar, python) visible even in a non-interactive shell.
export PATH="$HOME/miniforge3/Library/bin:$HOME/miniforge3:$HOME/miniforge3/Scripts:$PATH"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="$ROOT/Install_NDI_SDK_v6_Apple.pkg"
OUT="$ROOT/third_party/NDI"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$PKG" ] || { echo "ERROR: $PKG not found"; exit 1; }

echo "1/4 extracting installer payload..."
bsdtar -xf "$PKG" -C "$TMP" NDI_SDK_Component.pkg/Payload

echo "2/4 extracting lib + headers from payload..."
bsdtar -xf "$TMP/NDI_SDK_Component.pkg/Payload" -C "$TMP" \
  './NDI SDK for Apple/lib/iOS/libndi_ios.a' './NDI SDK for Apple/include'

mkdir -p "$OUT/include" "$OUT/lib"
cp "$TMP/NDI SDK for Apple/include/"*.h "$OUT/include/"

echo "3/4 carving arm64 device slice out of the universal lib..."
# Find a REAL python. Check conda/standalone installs first, then PATH, and
# skip the Microsoft Store stub (WindowsApps/python*.exe), which only nags to
# install from the Store. Honor an explicit PYTHON=... override if set.
if [ -z "${PYTHON:-}" ]; then
  PYTHON=""
  for cand in \
      "$HOME"/miniforge3/python.exe "$HOME"/miniconda3/python.exe "$HOME"/anaconda3/python.exe \
      "$HOME"/AppData/Local/Programs/Python/*/python.exe \
      "$(command -v python 2>/dev/null || true)" \
      "$(command -v python3 2>/dev/null || true)"; do
    case "$cand" in *WindowsApps*) continue;; esac           # skip the Store stub
    [ -n "$cand" ] && [ -x "$cand" ] && { PYTHON="$cand"; break; }
  done
fi
[ -n "$PYTHON" ] || { echo "ERROR: python not found (set PYTHON=/path/to/python.exe and re-run)"; exit 1; }
echo "    using python: $PYTHON"
"$PYTHON" - "$TMP/NDI SDK for Apple/lib/iOS/libndi_ios.a" "$OUT/lib/libndi_ios_arm64.a" <<'PY'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
d = open(src, "rb").read()
assert struct.unpack(">I", d[:4])[0] == 0xCAFEBABE, "not a fat Mach-O"
n = struct.unpack(">I", d[4:8])[0]
off, found = 8, None
for _ in range(n):
    ct, cs, so, ss, al = struct.unpack(">iiIII", d[off:off+20]); off += 20
    if (ct & 0xFFFFFFFF) == 0x0100000C:   # CPU_TYPE_ARM64
        found = (so, ss)
assert found, "no arm64 slice in library"
so, ss = found
assert d[so:so+8] == b"!<arch>\n", "arm64 slice is not an ar archive"
open(dst, "wb").write(d[so:so+ss])
print(f"    arm64 static lib: {ss/1e6:.1f} MB")
PY

echo "4/4 compressing (CI unzips this before linking)..."
gzip -9 -f "$OUT/lib/libndi_ios_arm64.a"   # -> libndi_ios_arm64.a.gz

echo
echo "Vendored:"
ls -la "$OUT/lib/"
echo "$(ls "$OUT/include/" | wc -l) headers in $OUT/include/"
echo "Done. Commit third_party/NDI/ (the .gz + headers)."
