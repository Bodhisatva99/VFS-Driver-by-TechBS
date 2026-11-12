#!/usr/bin/python3
"""Persistent VFS491 capture broker. Runs inside the service's private namespaces."""

from __future__ import annotations

import argparse
import errno
import os
import selectors
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
from pathlib import Path

SOCKET_PATH = os.environ.get("VFS491D_SOCKET", "/var/lib/vfs491/control.sock")
BRIDGE = os.environ.get("VFS491_BRIDGE_BIN", "/usr/libexec/vfs491/vfs491-bridge")
HELPER = os.environ.get("VFS491_HELPER_BIN", "/usr/libexec/vfs491/vfs_proprietary-capture-helper")
VENDOR_DIR = os.environ.get("VFS491_VENDOR_DIR", "/usr/lib/vfs491/vendor")
READFULL = os.environ.get("VFS491_READFULL_SHIM", "/usr/lib/vfs491/libvfs491-readfull.so")
READY_MARKER = os.environ.get("VFS491_READY_MARKER", "/tmp/vcsSemKey_ServiceReady")
MAX_FRAME = 20 + 200 * 1023
FRAME_HEADER = struct.Struct("<IIIII")
FRAME_MAGIC = 0x31534656
FRAME_VERSION = 1
IMAGE_WIDTH = 200

STOP = False


def log(message: str) -> None:
    print(f"vfs491d: {message}", file=sys.stderr, flush=True)


def on_signal(_signum: int, _frame: object) -> None:
    global STOP
    STOP = True


def read_command(conn: socket.socket, buffered: bytearray) -> tuple[bytes | None, bytearray]:
    while b"\n" not in buffered:
        chunk = conn.recv(4096)
        if not chunk:
            return None, buffered
        buffered.extend(chunk)
        if len(buffered) > 4096:
            raise ValueError("command line exceeds protocol limit")
    line, _, remainder = buffered.partition(b"\n")
    return line.strip(), bytearray(remainder)


def terminate_process(proc: subprocess.Popen[bytes]) -> None:
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            log("capture bridge did not exit after SIGKILL")


def validate_frame(frame: bytes) -> bool:
    if len(frame) < FRAME_HEADER.size or len(frame) > MAX_FRAME:
        return False
    magic, version, width, height, image_len = FRAME_HEADER.unpack_from(frame)
    return (
        magic == FRAME_MAGIC
        and version == FRAME_VERSION
        and width == IMAGE_WIDTH
        and 1 <= height <= 1023
        and image_len == width * height
        and len(frame) == FRAME_HEADER.size + image_len
    )


def capture_one(conn: socket.socket, initial_buffer: bytearray) -> tuple[int, bytearray, bool]:
    """Return (bridge status, frame, client_cancelled)."""
    env = os.environ.copy()
    env.update(
        {
            "VFS491_HP_LIBDIR": VENDOR_DIR,
            "VFS491_READFULL_SHIM": READFULL,
            "VFS491_READY_MARKER": READY_MARKER,
            "VFS491_SERVICE_START_WAIT_MS": "1000",
            "VFS491_BRIDGE_TIMEOUT_MS": "90000",
        }
    )
    proc = subprocess.Popen(
        [BRIDGE, HELPER],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=None,
        env=env,
        start_new_session=True,
        close_fds=True,
    )
    assert proc.stdout is not None
    os.set_blocking(proc.stdout.fileno(), False)
    conn.setblocking(False)
    selector = selectors.DefaultSelector()
    selector.register(conn, selectors.EVENT_READ, "client")
    selector.register(proc.stdout, selectors.EVENT_READ, "bridge")
    frame = bytearray()
    stdout_eof = False
    cancelled = False
    buffered = bytearray(initial_buffer)
    deadline = time.monotonic() + 110.0

    try:
        while True:
            if STOP or time.monotonic() >= deadline:
                cancelled = True
                break
            events = selector.select(0.25)
            for key, _mask in events:
                if key.data == "client":
                    try:
                        chunk = conn.recv(4096)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        cancelled = True
                        break
                    buffered.extend(chunk)
                    while b"\n" in buffered:
                        line, _, rest = buffered.partition(b"\n")
                        buffered = bytearray(rest)
                        if line.strip() == b"QUIT":
                            cancelled = True
                            break
                        log("unexpected command while capture is active")
                        cancelled = True
                        break
                    if cancelled:
                        break
                elif key.data == "bridge":
                    try:
                        chunk = os.read(proc.stdout.fileno(), 65536)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        stdout_eof = True
                        selector.unregister(proc.stdout)
                    else:
                        frame.extend(chunk)
                        if len(frame) > MAX_FRAME:
                            log("bridge output exceeded maximum frame size")
                            cancelled = True
                            break
            if cancelled:
                break
            status = proc.poll()
            if status is not None and stdout_eof:
                return status, frame, False
    finally:
        selector.close()
        if cancelled:
            terminate_process(proc)
        try:
            proc.stdout.close()
        except OSError:
            pass
        conn.setblocking(True)

    return (proc.returncode if proc.returncode is not None else 12), frame, True


def peer_is_root(conn: socket.socket) -> bool:
    if not hasattr(socket, "SO_PEERCRED"):
        return False
    try:
        _pid, uid, _gid = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        return uid == 0
    except OSError:
        return False


def serve_client(conn: socket.socket) -> None:
    conn.settimeout(None)
    if os.environ.get("VFS491D_TEST_MODE") != "1" and not peer_is_root(conn):
        conn.sendall(b"ERR 13\n")
        return
    conn.sendall(b"READY\n")
    buffered = bytearray()
    while not STOP:
        try:
            command, buffered = read_command(conn, buffered)
        except (OSError, ValueError) as exc:
            log(f"client protocol read failed: {exc}")
            return
        if command is None:
            return
        if command == b"QUIT":
            return
        if command != b"CAPTURE":
            conn.sendall(b"ERR 12\n")
            continue

        log("capture request received")
        try:
            status, frame, cancelled = capture_one(conn, buffered)
        except OSError as exc:
            log(f"capture bridge launch/read failed: {exc}")
            try:
                conn.sendall(b"ERR 12\n")
            except OSError:
                return
            buffered.clear()
            continue
        buffered.clear()
        if cancelled:
            log("capture cancelled by closing fprintd client; vendor service remains resident")
            return
        if status == 0 and validate_frame(bytes(frame)):
            conn.sendall(f"OK {len(frame)}\n".encode() + frame)
            log(f"delivered validated frame ({len(frame)} bytes)")
        else:
            if status == 0:
                log("bridge returned a malformed frame")
                status = 12
            if status not in (10, 11, 12):
                status = 12
            conn.sendall(f"ERR {status}\n".encode())
            log(f"capture returned bridge status {status}; vendor service remains resident")


def prepare_socket(path: str) -> socket.socket:
    socket_path = Path(path)
    socket_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        st = socket_path.lstat()
        if not stat.S_ISSOCK(st.st_mode):
            raise RuntimeError(f"refusing to replace non-socket path: {path}")
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.settimeout(1)
            probe.connect(path)
            raise RuntimeError(f"another VFS491 daemon is already listening at {path}")
        except OSError as exc:
            if exc.errno not in (errno.ECONNREFUSED, errno.ENOENT, errno.ECONNRESET):
                raise
        finally:
            probe.close()
        socket_path.unlink(missing_ok=True)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    os.chmod(path, 0o600)
    server.listen(4)
    server.settimeout(1.0)
    return server


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default=SOCKET_PATH)
    args = parser.parse_args()

    if os.environ.get("VFS491D_TEST_MODE") != "1" and os.geteuid() != 0:
        log("must run as root")
        return 1
    if os.environ.get("VFS491D_TEST_MODE") != "1":
        for executable in (BRIDGE, HELPER):
            if not os.path.isfile(executable) or not os.access(executable, os.X_OK):
                log(f"required executable missing: {executable}")
                return 1

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    server = None
    try:
        server = prepare_socket(args.socket)
        log(f"persistent capture broker ready at {args.socket}")
        while not STOP:
            try:
                conn, _address = server.accept()
            except socket.timeout:
                continue
            except OSError:
                if STOP:
                    break
                raise
            with conn:
                try:
                    serve_client(conn)
                except (BrokenPipeError, ConnectionResetError, OSError) as exc:
                    log(f"client disconnected: {exc}")
        return 0
    except Exception as exc:
        log(f"fatal: {exc}")
        return 1
    finally:
        if server is not None:
            server.close()
        try:
            Path(args.socket).unlink(missing_ok=True)
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
