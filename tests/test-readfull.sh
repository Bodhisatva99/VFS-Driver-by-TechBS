#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/vfs491-readfull-test.XXXXXX)"
# The shim intentionally matches the vendor's historical /tmp/CH_EVENT path.
FIFO="/tmp/CH_EVENT-vfs491-test-$$"
BIN="$TMP/readfull-fixture"
SHIM="$TMP/libvfs491-readfull.so"
DUMMY="$TMP/libexisting-preload.so"
LIVE="$TMP/live-output-fixture"
cleanup() { rm -f "$FIFO"; rm -rf "$TMP"; }
trap cleanup EXIT

mkfifo "$FIFO"
gcc -std=gnu11 -O2 -Wall -Wextra -Werror \
    "$ROOT/tests/readfull-fixture.c" -o "$BIN"
gcc -shared -fPIC -O2 -Wall -Wextra -Werror \
    "$ROOT/src/vfs491-readfull.c" -ldl -o "$SHIM"
printf 'void vfs491_test_existing_preload(void) {}\n' | \
    gcc -shared -fPIC -x c - -o "$DUMMY"
gcc -std=gnu11 -O2 -Wall -Wextra -Werror \
    "$ROOT/tests/live-output-fixture.c" -o "$LIVE"

plain="$("$BIN" "$FIFO")"
if [[ "$plain" -ge 8192 ]]; then
    echo "FAIL: control read unexpectedly consumed all FIFO chunks ($plain)" >&2
    exit 1
fi

with_shim="$(LD_PRELOAD="$SHIM" "$BIN" "$FIFO")"
if [[ "$with_shim" -ne 8192 ]]; then
    echo "FAIL: readfull shim returned $with_shim bytes; expected 8192" >&2
    exit 1
fi

wrapped="$(LD_PRELOAD="$DUMMY" VFS491_REAL_HELPER="$BIN" \
    VFS491_READFULL_SHIM="$SHIM" "$ROOT/scripts/vfs491-helper-launcher.sh" "$FIFO")"
if [[ "$wrapped" -ne 8192 ]]; then
    echo "FAIL: helper launcher did not append readfull shim ($wrapped bytes)" >&2
    exit 1
fi

printf 'PASS: control FIFO read returned a partial chunk (%s bytes)\n' "$plain"
printf 'PASS: CH_EVENT read shim aggregated all chunks (%s bytes)\n' "$with_shim"
printf 'PASS: production launcher preserved an existing preload and appended readfull (%s bytes)\n' "$wrapped"
python3 - "$ROOT/scripts/vfs491-helper-launcher.sh" "$LIVE" "$SHIM" "$DUMMY" <<'PYLIVE'
import os, select, subprocess, sys
launcher, live, readfull, dummy = sys.argv[1:]
env = os.environ.copy()
env.update({
    "VFS491_REAL_HELPER": live,
    "VFS491_READFULL_SHIM": readfull,
    "LD_PRELOAD": dummy,
})
proc = subprocess.Popen([launcher], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
ready, _, _ = select.select([proc.stdout], [], [], 1.0)
if not ready:
    proc.kill()
    proc.wait()
    raise SystemExit("FAIL: vendor helper output was not flushed while capture was active")
text = proc.stdout.read(5)
if text != b"SWIPE":
    proc.kill()
    proc.wait()
    raise SystemExit(f"FAIL: unexpected live output {text!r}")
proc.wait(timeout=4)
if proc.returncode != 0:
    raise SystemExit(f"FAIL: live-output fixture exited {proc.returncode}")
print("PASS: helper launcher flushes the swipe prompt before helper exit")
PYLIVE
