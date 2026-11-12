#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

VENDOR_DIR=/usr/lib/vfs491/vendor
FIRMWARE="$VENDOR_DIR/firmware/HPUsbVFS491.img"
BRIDGE=/usr/libexec/vfs491/vfs491-bridge
HELPER=/usr/libexec/vfs491/vfs_proprietary-capture-helper
READFULL=/usr/lib/vfs491/libvfs491-readfull.so
DAEMON=/usr/libexec/vfs491/vfs491d.py
SOCKET=/var/lib/vfs491/control.sock
READY_MARKER=/tmp/vcsSemKey_ServiceReady
SERVICE_ID=/tmp/vcsSemKey_ServiceId
SERVICE_PID=""
PIDOF_STAGED=""
FRAME_FILE=""
LAUNCHER_PID=""
NAMESPACE_ISOLATED=0
PRIVATE_MOUNTS_ACTIVE=0
SERVICE_LAUNCHED=0
CLEANING=0

log() { printf 'vfs491d: %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit "${2:-20}"; }

same_namespace() {
    local kind="$1" self_ns init_ns
    self_ns="$(readlink "/proc/self/ns/$kind")" || return 0
    init_ns="$(readlink "/proc/1/ns/$kind")" || return 0
    [[ "$self_ns" == "$init_ns" ]]
}

find_vendor_pids() {
    local proc exe base comm proc_mnt self_mnt proc_ipc self_ipc
    for proc in /proc/[0-9]*; do
        [[ -d "$proc" ]] || continue
        exe="$(readlink -f "$proc/exe" 2>/dev/null || true)"
        base="${exe##*/}"
        proc_mnt="$(readlink "$proc/ns/mnt" 2>/dev/null || true)"
        self_mnt="$(readlink /proc/self/ns/mnt 2>/dev/null || true)"
        proc_ipc="$(readlink "$proc/ns/ipc" 2>/dev/null || true)"
        self_ipc="$(readlink /proc/self/ns/ipc 2>/dev/null || true)"
        [[ "$proc_mnt" == "$self_mnt" && "$proc_ipc" == "$self_ipc" ]] || continue
        if [[ "$base" == vcsFPService ]]; then
            printf '%s\n' "${proc##*/}"
            continue
        fi
        comm="$(cat "$proc/comm" 2>/dev/null || true)"
        [[ "$comm" == vcsFPService ]] && printf '%s\n' "${proc##*/}"
    done
}

find_any_vendor_service() {
    local pids
    pids="$(find_vendor_pids || true)"
    [[ -z "$pids" ]] || { printf '%s\n' "${pids%%$'\n'*}"; return 0; }
    return 1
}

wait_sensor_stable() {
    local required="${1:-8}" deadline=$((SECONDS + 25))
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
            (( stable >= required )) && { log "VFS491 USB stable: $current"; return 0; }
        else
            previous="$current"
            stable=0
        fi
        sleep 0.1
    done
    return 1
}

stop_vendor_service() {
    local pid="${SERVICE_PID:-}" exe="" comm=""
    [[ -n "$pid" ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    if [[ "${exe##*/}" != vcsFPService && "$comm" != vcsFPService ]]; then
        log "service PID $pid no longer identifies vcsFPService; leaving it untouched"
        return 0
    fi
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || return 0
        exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        if [[ "${exe##*/}" != vcsFPService && "$comm" != vcsFPService ]]; then
            return 0
        fi
        sleep 0.1
    done
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    if [[ "${exe##*/}" == vcsFPService || "$comm" == vcsFPService ]]; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
}

cleanup() {
    local rc=$?
    (( CLEANING == 1 )) && return 0
    CLEANING=1
    trap - EXIT TERM INT HUP
    [[ -z "$FRAME_FILE" ]] || rm -f "$FRAME_FILE" || true
    # Never touch host service processes or host marker paths if isolation
    # validation failed or private mounts were not established.
    if (( NAMESPACE_ISOLATED == 1 )); then
        if (( SERVICE_LAUNCHED == 1 )); then
            # The daemon can be long-lived; stop only processes still identified
            # as the vendor executable inside this private service namespace.
            while IFS= read -r pid; do
                [[ -n "$pid" ]] || continue
                SERVICE_PID="$pid"
                stop_vendor_service
            done < <(find_vendor_pids || true)
        fi
        [[ -z "$PIDOF_STAGED" ]] || rm -f "$PIDOF_STAGED" || true
        if (( PRIVATE_MOUNTS_ACTIVE == 1 )); then
            rm -f "$READY_MARKER" "$SERVICE_ID" /run/ValidityService.pid
        fi
        rm -f "$SOCKET" || true
        log "persistent daemon stopped; private IPC namespace will be destroyed"
    fi
    return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

[[ $EUID -eq 0 ]] || fail "must run as root through fprintd"
if same_namespace mnt; then
    fail "mount namespace is not private; refusing to mount over host paths"
fi
if same_namespace ipc; then
    fail "IPC namespace is not private; refusing to start the vendor daemon"
fi
NAMESPACE_ISOLATED=1

for item in "$VENDOR_DIR/vcsFPService" "$VENDOR_DIR/libvfsFprintWrapper.so" \
            "$FIRMWARE" "$BRIDGE" "$HELPER" "$READFULL" "$DAEMON" \
            /usr/bin/stdbuf /usr/sbin/killall5; do
    [[ -e "$item" ]] || fail "required runtime file missing: $item"
done
[[ -x "$VENDOR_DIR/vcsFPService" && -x "$BRIDGE" && -x "$HELPER" && -x "$DAEMON" ]] || fail "runtime executable mode is invalid"
[[ -d /run/lock ]] || fail "/run/lock is unavailable before private /run setup"

# Hold the host-visible device lock for the entire boot-resident daemon lifetime.
exec 9>/run/lock/vfs491-capture.lock
flock -n 9 || fail "another VFS491 session is active" 21

if existing="$(find_any_vendor_service || true)" && [[ -n "$existing" ]]; then
    fail "another vcsFPService already exists (PID $existing); refusing to kill or reuse it"
fi

wait_sensor_stable 8 || fail "USB 138a:003d did not remain stable before service startup" 22

PIDOF_TARGET="$(readlink -f "$(command -v pidof || true)" 2>/dev/null || true)"
[[ "$PIDOF_TARGET" == /usr/sbin/* && -x "$PIDOF_TARGET" ]] || fail "pidof executable target is unavailable"
PIDOF_STAGED="$(mktemp /tmp/vfs491-pidof.XXXXXX)"
install -m 0755 "$PIDOF_TARGET" "$PIDOF_STAGED"

mount --make-rprivate /
mount -t tmpfs -o mode=0755,nosuid,nodev,size=1m tmpfs /run
mount -t tmpfs -o mode=0755,nosuid,nodev,size=2m tmpfs /usr/sbin
PRIVATE_MOUNTS_ACTIVE=1
mkdir -p -m 0755 /run/lock
install -m 0755 "$PIDOF_STAGED" /usr/sbin/killall5
rm -f "$PIDOF_STAGED"
PIDOF_STAGED=""
install -m 0644 "$FIRMWARE" /usr/sbin/HPUsbVFS491.img
rm -f "$READY_MARKER" "$SERVICE_ID"

log "starting persistent HP VFS491 service for the system lifetime"
SERVICE_LAUNCHED=1
(
    cd /
    export LD_LIBRARY_PATH="$VENDOR_DIR"
    exec "$VENDOR_DIR/vcsFPService"
) >/dev/null 2>&1 &
LAUNCHER_PID=$!

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
(( service_ready == 1 )) || fail "vcsFPService did not publish readiness within 30 seconds (launcher PID $LAUNCHER_PID)"
wait_sensor_stable 8 || fail "VFS491 USB did not stabilize after HP service startup" 22

export VFS491_HP_LIBDIR="$VENDOR_DIR"
export VFS491_READFULL_SHIM="$READFULL"
export VFS491_READY_MARKER="$READY_MARKER"
export VFS491_SERVICE_START_WAIT_MS=1000
export VFS491_BRIDGE_TIMEOUT_MS=90000

log "HP service ready (PID $SERVICE_PID); handing control to the persistent socket broker"
python3 "$DAEMON" --socket "$SOCKET"
