#!/usr/bin/env python3
import argparse
import os
import select
import struct
import subprocess
import sys
import time
import uuid

SESSION = "/usr/libexec/vfs491/vfs491-session"
SYSTEMD_RUN = "/usr/bin/systemd-run"
SYSTEMCTL = "/usr/bin/systemctl"
MAGIC = 0x31534656
VERSION = 1
WIDTH = 200
HEADER_SIZE = 20
MAX_HEIGHT = 1023


def read_line(stream, timeout, label):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for {label} after {timeout}s")
        ready, _, _ = select.select([stream], [], [], remaining)
        if not ready:
            continue
        byte = stream.read(1)
        if not byte:
            raise RuntimeError(f"session closed while waiting for {label}")
        if byte == b"\n":
            return data.decode("ascii", "replace").rstrip("\r")
        data.extend(byte)


def read_exact(stream, length, timeout):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while len(data) < length:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out reading frame ({len(data)}/{length} bytes)")
        ready, _, _ = select.select([stream], [], [], remaining)
        if not ready:
            continue
        chunk = stream.read(length - len(data))
        if not chunk:
            raise RuntimeError(f"session closed during frame ({len(data)}/{length} bytes)")
        data.extend(chunk)
    return bytes(data)


def stop_unit(unit):
    subprocess.run([SYSTEMCTL, "stop", "--no-block", unit],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   check=False)


def main():
    parser = argparse.ArgumentParser(description="Capture repeated VFS491 swipes in one isolated HP service session")
    parser.add_argument("--captures", type=int, default=2, choices=range(1, 6))
    parser.add_argument("--capture-timeout", type=int, default=110)
    args = parser.parse_args()

    if os.geteuid() != 0:
        raise SystemExit("Run with sudo: sudo ./scripts/test-capture-session.py --captures 2")
    if not os.path.isfile(SESSION) or not os.access(SESSION, os.X_OK):
        raise SystemExit(f"Installed session supervisor not found: {SESSION}")

    unit = "vfs491-manual-session-" + uuid.uuid4().hex[:12]
    argv = [
        SYSTEMD_RUN, "--quiet", "--wait", "--pipe", "--collect", "--unit", unit,
        "--property=Type=exec", "--property=PrivateMounts=yes",
        "--property=PrivateIPC=yes", "--property=PrivateTmp=yes",
        "--property=KillMode=control-group", "--property=TimeoutStartSec=25s",
        "--property=TimeoutStopSec=8s", "--property=RuntimeMaxSec=240s",
        "--property=UMask=0077", SESSION,
    ]

    # Unbuffered pipes keep select() consistent with bytes available to read;
    # BufferedReader may prefetch frame bytes after the protocol line.
    session_started = time.monotonic()
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=None, bufsize=0, text=False)
    try:
        assert proc.stdin is not None and proc.stdout is not None
        ready = read_line(proc.stdout, 45, "session READY")
        if ready != "READY":
            raise RuntimeError(f"unexpected session startup response: {ready!r}")
        print(f"PASS: one isolated HP service session is ready in {time.monotonic() - session_started:.3f}s")

        for number in range(1, args.captures + 1):
            capture_started = time.monotonic()
            print(f"Capture {number}/{args.captures}: swipe one finger when the helper says 'Waiting for finger swipe ...'", flush=True)
            proc.stdin.write(b"CAPTURE\n")
            proc.stdin.flush()
            response = read_line(proc.stdout, args.capture_timeout + 20, "capture response")
            if response.startswith("ERR "):
                status = int(response.split()[1])
                raise RuntimeError(f"capture transaction returned status {status}")
            if not response.startswith("OK "):
                raise RuntimeError(f"unexpected capture response: {response!r}")
            frame_size = int(response.split()[1])
            if frame_size < HEADER_SIZE or frame_size > HEADER_SIZE + WIDTH * MAX_HEIGHT:
                raise RuntimeError(f"invalid frame size: {frame_size}")
            frame = read_exact(proc.stdout, frame_size, 15)
            magic, version, width, height, image_len = struct.unpack("<IIIII", frame[:HEADER_SIZE])
            if magic != MAGIC or version != VERSION or width != WIDTH or not (1 <= height <= MAX_HEIGHT):
                raise RuntimeError(f"invalid VFS491 frame header: {width}x{height}, version={version}")
            if image_len != width * height or len(frame) != HEADER_SIZE + image_len:
                raise RuntimeError(f"invalid grayscale payload length: {image_len}, frame={len(frame)}")
            print(f"PASS: capture {number}: {width}x{height}, {image_len} grayscale bytes in {time.monotonic() - capture_started:.3f}s")

        proc.stdin.write(b"QUIT\n")
        proc.stdin.flush()
        proc.stdin.close()
        status = proc.wait(timeout=15)
        if status != 0:
            raise RuntimeError(f"session exited with status {status}")
        print("PASS: repeated captures used one HP service session; session cleaned up")
    except Exception:
        stop_unit(unit)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
        raise


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
