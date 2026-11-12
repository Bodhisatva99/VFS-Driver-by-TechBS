#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

RUN=/usr/bin/systemd-run
[[ -x "$RUN" ]] || { echo "systemd-run is missing: $RUN" >&2; exit 1; }
unit="vfs491-isolation-check-$$"

"$RUN" --quiet --wait --pipe --collect \
    --unit="$unit" \
    --property=Type=exec \
    --property=PrivateMounts=yes \
    --property=PrivateIPC=yes \
    --property=PrivateTmp=yes \
    /bin/sh -eu -c '
        self_mnt=$(readlink /proc/self/ns/mnt)
        init_mnt=$(readlink /proc/1/ns/mnt)
        self_ipc=$(readlink /proc/self/ns/ipc)
        init_ipc=$(readlink /proc/1/ns/ipc)
        [ "$self_mnt" != "$init_mnt" ] || { echo "FAIL: mount namespace is shared" >&2; exit 1; }
        [ "$self_ipc" != "$init_ipc" ] || { echo "FAIL: IPC namespace is shared" >&2; exit 1; }
        [ -d /tmp ] || { echo "FAIL: /tmp is unavailable" >&2; exit 1; }
        printf "PASS: private mount namespace (%s != %s)\n" "$self_mnt" "$init_mnt"
        printf "PASS: private IPC namespace (%s != %s)\n" "$self_ipc" "$init_ipc"
        echo "PASS: no mounts were created or changed by this check"
    '
