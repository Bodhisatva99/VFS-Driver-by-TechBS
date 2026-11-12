#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

VENDOR_DIR=/usr/lib/vfs491/vendor
FIRMWARE="$VENDOR_DIR/firmware/HPUsbVFS491.img"
BRIDGE=/usr/libexec/vfs491/vfs491-bridge
HELPER=/usr/libexec/vfs491/vfs_proprietary-capture-helper
READY_MARKER=/tmp/vcsSemKey_ServiceReady
SERVICE_ID=/tmp/vcsSemKey_ServiceId
SERVICE_PID=""
PIDOF_COMMAND=""
PIDOF_TARGET=""
PIDOF_TARGET_NAME=""
PIDOF_STAGED=""
BRIDGE_PID=""
LAUNCHER_PID=""
CLEANING=0

log() { printf 'vfs491-transaction: %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit "${2:-20}"; }

require_file() {
    local file="$1" mode="$2"
    [[ -f "$file" ]] || fail "required file missing: $file"
    [[ -r "$file" ]] || fail "required file is not readable: $file"
    if [[ "$mode" == x && ! -x "$file" ]]; then
        fail "required executable is not executable: $file"
    fi
}

same_namespace() {
    local kind="$1" self_ns init_ns
    self_ns="$(readlink "/proc/self/ns/$kind")" || return 0
    init_ns="$(readlink "/proc/1/ns/$kind")" || return 0
    [[ "$self_ns" == "$init_ns" ]]
}

find_vendor_pids() {
    local proc exe
    for proc in /proc/[0-9]*; do
        [[ -d "$proc" ]] || continue
        exe="$(readlink -f "$proc/exe" 2>/dev/null || true)"
        [[ "$exe" == "$VENDOR_DIR/vcsFPService" ]] && printf '%s\n' "${proc##*/}"
    done
}

find_any_vendor_service() {
    local proc exe base comm
    for proc in /proc/[0-9]*; do
        [[ -d "$proc" ]] || continue
        exe="$(readlink -f "$proc/exe" 2>/dev/null || true)"
        base="${exe##*/}"
        if [[ "$base" == vcsFPService ]]; then
            printf '%s\n' "${proc##*/}"
            return 0
        fi
        comm="$(cat "$proc/comm" 2>/dev/null || true)"
        if [[ "$comm" == vcsFPService ]]; then
            printf '%s\n' "${proc##*/}"
            return 0
        fi
    done
    return 1
}

wait_sensor_stable() {
    local deadline=$((SECONDS + 25))
    local current="" previous="" stable=0 path vendor product devnum
    while (( SECONDS < deadline )); do
        current=""
        for path in /sys/bus/usb/devices/*; do
            [[ -r "$path/idVendor" && -r "$path/idProduct" && -r "$path/devnum" ]] || continue
            vendor="$(<"$path/idVendor")"
            product="$(<"$path/idProduct")"
            [[ "$vendor" == 138a && "$product" == 003d ]] || continue
            devnum="$(<"$path/devnum")"
            current="${path##*/}:$devnum"
            break
        done
        if [[ -n "$current" && "$current" == "$previous" ]]; then
            stable=$((stable + 1))
            (( stable >= 15 )) && { log "VFS491 USB stable: $current"; return 0; }
        else
            previous="$current"
            stable=0
        fi
        sleep 0.1
    done
    return 1
}

stop_matching_vendor_processes() {
    local pids=() pid
    mapfile -t pids < <(find_vendor_pids || true)
    for pid in "${pids[@]:-}"; do
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    done
    for _ in $(seq 1 40); do
        local alive=0
        for pid in "${pids[@]:-}"; do
            [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && alive=1 || true
        done
        (( alive == 0 )) && break
        sleep 0.1
    done
    for pid in "${pids[@]:-}"; do
        [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
    done
}

cleanup() {
    local rc=$?
    (( CLEANING == 1 )) && return 0
    CLEANING=1
    trap - EXIT TERM INT HUP

    if [[ -n "$BRIDGE_PID" ]] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
        kill -TERM "$BRIDGE_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$BRIDGE_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$BRIDGE_PID" 2>/dev/null || true
        wait "$BRIDGE_PID" 2>/dev/null || true
    fi

    stop_matching_vendor_processes
    if [[ -n "$PIDOF_STAGED" ]]; then
        rm -f "$PIDOF_STAGED" || true
    fi
    rm -f "$READY_MARKER" "$SERVICE_ID" /run/ValidityService.pid
    log "transaction cleanup complete (SysV IPC is scoped to this unit's private IPC namespace)"
    return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

[[ $EUID -eq 0 ]] || fail "must run as root through the system fprintd service"

# These checks MUST precede every mount call. A direct invocation in the host
# namespace is rejected, preventing the old /run and /usr/sbin overlay failure.
if same_namespace mnt; then
    fail "mount namespace is not private; refusing to mount over host paths"
fi
if same_namespace ipc; then
    fail "IPC namespace is not private; refusing to start the vendor daemon"
fi

require_file "$VENDOR_DIR/vcsFPService" x
require_file "$VENDOR_DIR/libvfsFprintWrapper.so" r
require_file "$FIRMWARE" r
require_file "$BRIDGE" x
require_file "$HELPER" x
require_file /usr/lib/vfs491/libvfs491-readfull.so r
require_file /usr/bin/stdbuf x
[[ -d /run/lock ]] || fail "/run/lock is unavailable before private /run setup"

# Open the host-visible lock before masking /run. The descriptor continues to
# lock the same inode after the private tmpfs is mounted over /run.
exec 9>/run/lock/vfs491-capture.lock
flock -n 9 || fail "another VFS491 capture transaction is active" 21

if existing="$(find_any_vendor_service || true)" && [[ -n "$existing" ]]; then
    fail "another vcsFPService already exists (PID $existing); refusing to kill or reuse it"
fi

wait_sensor_stable || fail "USB 138a:003d did not remain stable before service startup" 22

# Ubuntu pidof resolves through /usr/sbin/killall5. Stage the target before
# the private /usr/sbin tmpfs hides it, then restore it inside this namespace.
PIDOF_COMMAND="$(command -v pidof || true)"
[[ -n "$PIDOF_COMMAND" ]] || fail "pidof command missing; sysvinit-utils is required"
PIDOF_TARGET="$(readlink -f "$PIDOF_COMMAND" 2>/dev/null || true)"
[[ -n "$PIDOF_TARGET" && -x "$PIDOF_TARGET" ]] || fail "pidof executable target unavailable: $PIDOF_TARGET"
case "$PIDOF_TARGET" in
    /usr/sbin/*) ;;
    *) fail "unexpected pidof executable location: $PIDOF_TARGET" ;;
esac
PIDOF_TARGET_NAME="${PIDOF_TARGET##*/}"
PIDOF_STAGED="$(mktemp /tmp/vfs491-pidof.XXXXXX)"
install -m 0755 "$PIDOF_TARGET" "$PIDOF_STAGED"

mount --make-rprivate /
mount -t tmpfs -o mode=0755,nosuid,nodev,size=1m tmpfs /run
mount -t tmpfs -o mode=0755,nosuid,nodev,size=2m tmpfs /usr/sbin
install -m 0755 "$PIDOF_STAGED" "/usr/sbin/$PIDOF_TARGET_NAME"
rm -f "$PIDOF_STAGED"
PIDOF_STAGED=""
install -m 0644 "$FIRMWARE" /usr/sbin/HPUsbVFS491.img
rm -f "$READY_MARKER" "$SERVICE_ID"

log "starting one-use HP VFS491 service in this private transaction"
(
    cd /
    export LD_LIBRARY_PATH="$VENDOR_DIR"
    exec "$VENDOR_DIR/vcsFPService"
) >/dev/null 2>&1 &
LAUNCHER_PID=$!

# Do not stop polling merely because the initial vendor launcher exits: the
# binary may daemonize and publish readiness from its child process.
service_ready=0
for _ in $(seq 1 120); do
    mapfile -t pids < <(find_vendor_pids || true)
    if (( ${#pids[@]} > 0 )) && [[ -e "$READY_MARKER" ]]; then
        SERVICE_PID="${pids[0]}"
        service_ready=1
        break
    fi
    sleep 0.25
done

if (( service_ready == 0 )); then
    fail "vcsFPService did not publish readiness within 30 seconds (launcher PID $LAUNCHER_PID)"
fi

wait_sensor_stable || fail "VFS491 USB did not stabilize after HP service startup" 22
log "HP service ready (PID $SERVICE_PID); starting the preserved legacy capture helper"

export VFS491_HP_LIBDIR="$VENDOR_DIR"
export VFS491_READFULL_SHIM="/usr/lib/vfs491/libvfs491-readfull.so"
export VFS491_READY_MARKER="$READY_MARKER"
export VFS491_SERVICE_START_WAIT_MS=5000
export VFS491_BRIDGE_TIMEOUT_MS=90000

"$BRIDGE" "$HELPER" &
BRIDGE_PID=$!
set +e
wait "$BRIDGE_PID"
bridge_status=$?
set -e
BRIDGE_PID=""

case "$bridge_status" in
    0)
        log "capture completed; returning one validated VFS1 frame"
        exit 0
        ;;
    10)
        log "no swipe detected before the vendor capture timeout"
        exit 10
        ;;
    11)
        log "vendor returned a recoverable acquisition error"
        exit 11
        ;;
    12)
        log "capture helper terminated abnormally"
        exit 12
        ;;
    3)
        fail "HP service readiness was lost before the bridge capture"
        ;;
    *)
        fail "bridge failed with status $bridge_status"
        ;;
esac
