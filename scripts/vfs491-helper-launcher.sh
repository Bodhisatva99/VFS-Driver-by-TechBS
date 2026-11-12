#!/usr/bin/env bash
set -Eeuo pipefail

REAL_HELPER="${VFS491_REAL_HELPER:-/usr/libexec/vfs491/vfs_proprietary-capture-helper.real}"
READFULL="${VFS491_READFULL_SHIM:-/usr/lib/vfs491/libvfs491-readfull.so}"
STDBUF="${VFS491_STDBUF:-/usr/bin/stdbuf}"

[[ -x "$REAL_HELPER" ]] || { echo "VFS491: real capture helper is missing: $REAL_HELPER" >&2; exit 127; }
[[ -r "$READFULL" ]] || { echo "VFS491: event-read compatibility shim is missing: $READFULL" >&2; exit 127; }
[[ -x "$STDBUF" ]] || { echo "VFS491: stdbuf is missing: $STDBUF" >&2; exit 127; }

# Match the 0.3.2 reference path: preload only the CH_EVENT full-read shim.
PRELOAD="${LD_PRELOAD:-}"
case ":$PRELOAD:" in
    *":$READFULL:"*) ;;
    *)
        if [[ -n "$PRELOAD" ]]; then
            export LD_PRELOAD="$PRELOAD:$READFULL"
        else
            export LD_PRELOAD="$READFULL"
        fi
        ;;
esac

# Keep the vendor helper's no-newline swipe prompt visible while capture is active.
# GNU stdbuf prepends its own preload while retaining both existing shims.
exec "$STDBUF" --output=0 --error=0 "$REAL_HELPER" "$@"
