#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
STAGE="$BUILD/package-root"
DEBS="$ROOT/debs"
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
CORE_VERSION="$(dpkg-query -W -f='${Version}' libfprint-2-2)"
TOD_VERSION="$(dpkg-query -W -f='${Version}' libfprint-2-tod1)"

[[ "$CORE_VERSION" == "$TOD_VERSION" ]] || {
    echo "Installed libfprint core/TOD versions differ; refusing package build." >&2
    exit 1
}
case "$TOD_VERSION" in
    *1.94.7+tod1*) ;;
    *) echo "Unsupported target TOD ABI: $TOD_VERSION" >&2; exit 1 ;;
esac

"$ROOT/scripts/build.sh"
bash -n "$ROOT/scripts/vfs491d-launcher.sh"
python3 -m py_compile "$ROOT/scripts/vfs491d.py" "$ROOT/scripts/vfs491-client.py" \
    "$ROOT/scripts/vfs491-wait-ready.py" "$ROOT/scripts/vfs491-image-diagnostics.py"
"$ROOT/scripts/verify-vendor.sh"

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" \
    "$STAGE/usr/lib/$MULTIARCH/libfprint-2/tod-1" \
    "$STAGE/usr/lib/vfs491/vendor/firmware" \
    "$STAGE/usr/libexec/vfs491" \
    "$STAGE/usr/share/doc/vfs491-fprintd-tod" \
    "$STAGE/lib/systemd/system"

install -m 0644 "$BUILD/tod/libfprint-tod-vfs491.so" \
    "$STAGE/usr/lib/$MULTIARCH/libfprint-2/tod-1/libfprint-tod-vfs491.so"
install -m 0755 "$BUILD/vfs491-bridge" \
    "$STAGE/usr/libexec/vfs491/vfs491-bridge"
install -m 0755 "$ROOT/scripts/vfs491d-launcher.sh" \
    "$STAGE/usr/libexec/vfs491/vfs491d-launcher"
install -m 0755 "$ROOT/scripts/vfs491d.py" \
    "$STAGE/usr/libexec/vfs491/vfs491d.py"
install -m 0755 "$ROOT/scripts/vfs491-client.py" \
    "$STAGE/usr/libexec/vfs491/vfs491-client"
install -m 0755 "$ROOT/scripts/vfs491-wait-ready.py" \
    "$STAGE/usr/libexec/vfs491/vfs491-wait-ready"
install -m 0755 "$ROOT/scripts/vfs491-image-diagnostics.py" \
    "$STAGE/usr/libexec/vfs491/vfs491-image-diagnostics"
install -m 0755 "$ROOT/reference/working-prototype/vfs_proprietary-capture-helper.reference" \
    "$STAGE/usr/libexec/vfs491/vfs_proprietary-capture-helper.real"
install -m 0755 "$ROOT/scripts/vfs491-helper-launcher.sh" \
    "$STAGE/usr/libexec/vfs491/vfs_proprietary-capture-helper"
install -m 0644 "$BUILD/libvfs491-readfull.so" \
    "$STAGE/usr/lib/vfs491/libvfs491-readfull.so"
install -m 0755 "$ROOT/vendor/compat/vcsFPService" \
    "$STAGE/usr/lib/vfs491/vendor/vcsFPService"
install -m 0644 "$ROOT/vendor/compat/libvfsFprintWrapper.so" \
    "$STAGE/usr/lib/vfs491/vendor/libvfsFprintWrapper.so"
install -m 0644 "$ROOT/vendor/original/HPUsbVFS491.img" \
    "$STAGE/usr/lib/vfs491/vendor/firmware/HPUsbVFS491.img"
install -m 0644 "$ROOT/systemd/vfs491d.service" \
    "$STAGE/lib/systemd/system/vfs491d.service"
install -m 0644 "$ROOT/README.md" "$STAGE/usr/share/doc/vfs491-fprintd-tod/README.md"
install -m 0644 "$ROOT/CHANGELOG.md" "$STAGE/usr/share/doc/vfs491-fprintd-tod/CHANGELOG.md"
install -m 0644 "$ROOT/docs/ARCHITECTURE-1.0.0.md" \
    "$STAGE/usr/share/doc/vfs491-fprintd-tod/ARCHITECTURE-1.0.0.md"
install -m 0644 "$ROOT/docs/RECOGNITION-PIPELINE.md" \
    "$STAGE/usr/share/doc/vfs491-fprintd-tod/RECOGNITION-PIPELINE.md"

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: vfs491-fprintd-tod
Version: 1.0.0~transaction9-1
Section: admin
Priority: optional
Architecture: amd64
Depends: libc6, libglib2.0-0, libusb-0.1-4, libusb-1.0-0, libudev1, libfprint-2-2 (= $CORE_VERSION), libfprint-2-tod1 (= $TOD_VERSION), fprintd, systemd, util-linux, sysvinit-utils, bash, coreutils, python3
Maintainer: VFS491 Linux Driver Project
Description: HP Validity VFS491 persistent-service TOD driver
 Native libfprint TOD backend for HP/Synaptics SP84530 Validity VFS491 sensors.
 Keeps one isolated HP vendor service resident for the system lifetime and
 exposes a root-only local socket to per-claim fprintd clients. Uses the 0.3.2
 reference helper for every swipe and the CH_EVENT full-read compatibility shim.
 Includes local capture-quality diagnostics; the Bozorth3 threshold stays at
 the libfprint default. PAM and LightDM are not modified.
CONTROL

cat > "$STAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = configure ] && [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    systemctl enable vfs491d.service
    systemctl start vfs491d.service
fi
exit 0
POSTINST

cat > "$STAGE/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
case "$1" in
    remove|deconfigure|upgrade|failed-upgrade)
        systemctl disable --now vfs491d.service || true
        ;;
esac
exit 0
PRERM

cat > "$STAGE/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
systemctl daemon-reload || true
exit 0
POSTRM

chmod 0755 "$STAGE/DEBIAN" "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"
chmod 0644 "$STAGE/DEBIAN/control"
mkdir -p "$DEBS"
DEB="$DEBS/vfs491-fprintd-tod_1.0.0~transaction9-1_amd64.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB"
echo "Built VFS491 Transaction 9 recognition-diagnostics package: $DEB"
dpkg-deb -f "$DEB" Package Version Architecture Depends
