#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORIG="$ROOT/vendor/original"
COMPAT="$ROOT/vendor/compat"
command -v patchelf >/dev/null || { echo "patchelf is required." >&2; exit 1; }
for file in vcsFPService libvfsFprintWrapper.so; do
  [[ -f "$ORIG/$file" ]] || { echo "Missing vendor original: $ORIG/$file" >&2; exit 1; }
  install -m 0755 "$ORIG/$file" "$COMPAT/$file"
done
for file in "$COMPAT/vcsFPService" "$COMPAT/libvfsFprintWrapper.so"; do
  patchelf --remove-needed libssl.so.0.9.8 "$file" 2>/dev/null || true
  patchelf --remove-needed libcrypto.so.0.9.8 "$file" 2>/dev/null || true
done
# Preserve the dependency-adjusted, unpatched wrapper before applying the
# tested code adjustment. This is the intended .pre-default-config backup.
cp -p "$COMPAT/libvfsFprintWrapper.so" "$COMPAT/libvfsFprintWrapper.so.pre-default-config"
python3 - "$COMPAT/libvfsFprintWrapper.so" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
data = bytearray(p.read_bytes())
offset = 0x11967
expected = bytes.fromhex("48 85 f6 48 0f 44 35 1e 36 23 00")
if len(data) < offset + len(expected):
    raise SystemExit("Wrapper is shorter than the validated patch offset")
current = bytes(data[offset:offset + len(expected)])
if current == b"\x90" * len(expected):
    print("Wrapper compatibility patch is already present")
elif current == expected:
    data[offset:offset + len(expected)] = b"\x90" * len(expected)
    p.write_bytes(data)
    print("Applied validated 11-byte compatibility patch at 0x11967")
else:
    raise SystemExit(f"Unexpected wrapper bytes at 0x{offset:x}: {current.hex(' ')}; refusing to patch")
PY
chmod 0755 "$COMPAT/vcsFPService" "$COMPAT/libvfsFprintWrapper.so"
sha256sum "$ORIG/vcsFPService" "$ORIG/libvfsFprintWrapper.so" "$ORIG"/firmware/*.img \
  "$ORIG/HPUsbVFS491.img" "$COMPAT/vcsFPService" "$COMPAT/libvfsFprintWrapper.so" \
  "$COMPAT/libvfsFprintWrapper.so.pre-default-config" > "$ROOT/vendor/vendor-sha256.txt"
if readelf -d "$COMPAT/vcsFPService" "$COMPAT/libvfsFprintWrapper.so" | grep -Eq 'NEEDED.*lib(ssl|crypto)\.so'; then
  echo "Legacy OpenSSL dependency remains in compatibility files." >&2; exit 1
fi
echo "Compatibility files prepared locally; originals remain unchanged."
