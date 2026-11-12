#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSROOT="$ROOT/sysroot"
DEBS="$ROOT/debs"
mkdir -p "$SYSROOT" "$DEBS"

# Reuse the build-only sysroot included in the local reference bundle when it
# already contains every header needed by the source checks and TOD build.
if [[ -f "$SYSROOT/usr/include/glib-2.0/glib.h" ]] &&
   find "$SYSROOT/usr/include" -type f -name 'gusb.h' -print -quit | grep -q . &&
   find "$SYSROOT/usr/include" -type f -path '*/libusb-1.0/libusb.h' -print -quit | grep -q . &&
   find "$SYSROOT/usr/include" -type f -path '*/json-glib/json-glib.h' -print -quit | grep -q .; then
  echo "Existing private build sysroot is complete; no downloads or system changes needed."
  exit 0
fi

# These packages are downloaded and unpacked only. Nothing is installed and
# no system runtime library is upgraded. GLib/GUsb headers are build inputs.
PACKAGES=(
  libglib2.0-dev
  libffi-dev
  libgusb-dev
  libusb-1.0-0-dev
  libjson-glib-dev
)

cd "$DEBS"
echo "Downloading development package archives (no installation)..."
for package in "${PACKAGES[@]}"; do
  # Keep an already downloaded package archive. This makes bootstrap safe to
  # rerun and avoids accumulating several versions of the same package.
  if compgen -G "${package}_*.deb" >/dev/null; then
    echo "  already present: $package"
  else
    apt-get download "$package"
  fi
done

echo "Extracting archives into $SYSROOT ..."
shopt -s nullglob
for deb in ./*.deb; do
  dpkg-deb -x "$deb" "$SYSROOT"
done

echo
echo "Private sysroot prepared. System packages were not installed or upgraded."
echo "Found headers:"
find "$SYSROOT/usr/include" -type f \( -name glib.h -o -name gio.h -o -name gobject.h -o -name gusb.h -o -name libusb.h -o -name json-glib.h -o -name ffi.h \) -print | sort
