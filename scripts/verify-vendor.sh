#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V="$ROOT/vendor"
for f in \
    "$V/compat/vcsFPService" \
    "$V/compat/libvfsFprintWrapper.so" \
    "$V/original/HPUsbVFS491.img"; do
    [[ -s "$f" ]] || { echo "Missing vendor payload: $f" >&2; exit 1; }
done
if readelf -d "$V/compat/vcsFPService" "$V/compat/libvfsFprintWrapper.so" 2>/dev/null | grep -Eq 'lib(ssl|crypto)\.so'; then
    echo "Vendor payload requests legacy OpenSSL libraries; refusing the build." >&2
    exit 1
fi
if [[ -f "$V/vendor-sha256.txt" ]]; then
    (cd "$V" && sha256sum -c vendor-sha256.txt)
else
    echo "No vendor-sha256.txt supplied; recording current payload hashes only."
    (cd "$V" && sha256sum compat/vcsFPService compat/libvfsFprintWrapper.so original/HPUsbVFS491.img)
fi
