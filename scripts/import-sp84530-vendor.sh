#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT="${1:-}"
[[ -n "$INPUT" ]] || {
    echo "Usage: $0 /path/to/SP84530.rpm|SP84530.tar|extracted-payload-directory" >&2
    exit 2
}
for tool in file readelf patchelf; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 3; }
done
TMP="$ROOT/build/vendor-import"
rm -rf "$TMP"
mkdir -p "$TMP/extract" "$ROOT/vendor/original/firmware" "$ROOT/vendor/compat"

if [[ -d "$INPUT" ]]; then
    cp -a "$INPUT"/. "$TMP/extract"/
elif file -b "$INPUT" | grep -qi 'RPM'; then
    for tool in rpm2cpio cpio; do
        command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 3; }
    done
    rpm2cpio "$INPUT" | (cd "$TMP/extract" && cpio -idm --quiet)
elif file -b "$INPUT" | grep -qiE 'tar archive|gzip compressed data|XZ compressed data'; then
    tar -xf "$INPUT" -C "$TMP/extract"
else
    echo "Unsupported SP84530 input format: $(file -b "$INPUT")" >&2
    exit 4
fi

SERVICE="$(find "$TMP/extract" -type f -name vcsFPService -print -quit)"
WRAPPER="$(find "$TMP/extract" -type f -name libvfsFprintWrapper.so -print -quit)"
[[ -n "$SERVICE" && -n "$WRAPPER" ]] || {
    echo "SP84530 input is missing vcsFPService or libvfsFprintWrapper.so." >&2
    exit 5
}
install -m 0755 "$SERVICE" "$ROOT/vendor/original/vcsFPService"
install -m 0755 "$WRAPPER" "$ROOT/vendor/original/libvfsFprintWrapper.so"
for fw in HPUsbVFS491.img; do
    found="$(find "$TMP/extract" -type f -name "$fw" -print -quit)"
    [[ -n "$found" ]] || { echo "SP84530 input is missing $fw" >&2; exit 5; }
    install -m 0644 "$found" "$ROOT/vendor/original/firmware/$fw"
done
install -m 0644 "$ROOT/vendor/original/firmware/HPUsbVFS491.img" \
    "$ROOT/vendor/original/HPUsbVFS491.img"
"$ROOT/scripts/prepare-vendor-compat.sh"
echo "SP84530 extracted into the project only. Nothing was installed system-wide."
