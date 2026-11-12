#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

RUN=/usr/bin/systemd-run
TRANSACTION="$ROOT/scripts/vfs491-capture-transaction.sh"
FRAME="$(mktemp /tmp/vfs491-frame.XXXXXX)"
UNIT="vfs491-manual-$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
cleanup() { rm -f "$FRAME"; }
trap cleanup EXIT

printf 'Wait for the live message: Waiting for finger swipe ... then make one continuous swipe.\n'
"$RUN" --quiet --wait --pipe --collect \
    --unit="$UNIT" \
    --property=Type=exec \
    --property=PrivateMounts=yes \
    --property=PrivateIPC=yes \
    --property=PrivateTmp=yes \
    --property=KillMode=control-group \
    --property=TimeoutStartSec=20s \
    --property=TimeoutStopSec=8s \
    --property=RuntimeMaxSec=240s \
    --property=UMask=0077 \
    "$TRANSACTION" >"$FRAME"

python3 - "$FRAME" <<'PY'
import struct
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_bytes()
if len(raw) < 20:
    raise SystemExit(f"FAIL: truncated frame ({len(raw)} bytes)")
magic, version, width, height, length = struct.unpack_from("<5I", raw)
if magic != 0x31534656 or version != 1 or width != 200:
    raise SystemExit(f"FAIL: invalid VFS1 header {magic:#x}/{version}, width={width}")
if not (1 <= height <= 1023) or length != width * height:
    raise SystemExit(f"FAIL: invalid dimensions {width}x{height}, length={length}")
if len(raw) != 20 + length:
    raise SystemExit(f"FAIL: frame length mismatch, got {len(raw)}, expected {20+length}")
print(f"PASS: VFS491 transaction returned {width}x{height}, {length} grayscale bytes")
PY
