#!/usr/bin/env python3
import os
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DAEMON = ROOT / "scripts/vfs491d.py"
CLIENT = ROOT / "scripts/vfs491-client.py"
FAKE_BRIDGE = ROOT / "tests/fake-persistent-bridge.py"


def read_line(stream, timeout=8):
    ready, _, _ = select.select([stream], [], [], timeout)
    if not ready:
        raise TimeoutError("timed out waiting for broker protocol line")
    line = stream.readline()
    if not line:
        raise RuntimeError("client closed before protocol line")
    return line.decode().rstrip("\n")


def read_exact(stream, length, timeout=8):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while len(data) < length:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"truncated frame: {len(data)}/{length}")
        ready, _, _ = select.select([stream], [], [], remaining)
        if not ready:
            continue
        chunk = os.read(stream.fileno(), length - len(data))
        if not chunk:
            raise RuntimeError(f"truncated frame: {len(data)}/{length}")
        data.extend(chunk)
    return bytes(data)


def connect_client(socket_path, env):
    client_env = env.copy()
    client_env["VFS491D_SOCKET"] = str(socket_path)
    client_env["VFS491_CLIENT_TEST_MODE"] = "1"
    proc = subprocess.Popen(
        [sys.executable, str(CLIENT)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=client_env,
        bufsize=0,
    )
    assert proc.stdin is not None and proc.stdout is not None
    assert read_line(proc.stdout) == "READY"
    return proc


def capture(proc, number):
    assert proc.stdin is not None and proc.stdout is not None
    proc.stdin.write(b"CAPTURE\n")
    proc.stdin.flush()
    line = read_line(proc.stdout)
    assert line.startswith("OK "), line
    length = int(line.split()[1])
    frame = read_exact(proc.stdout, length)
    magic, version, width, height, image_len = struct.unpack("<IIIII", frame[:20])
    assert (magic, version, width, height) == (0x31534656, 1, 200, 2)
    assert image_len == width * height
    assert len(frame) == 20 + image_len
    print(f"PASS: persistent broker capture {number}: {width}x{height}, {image_len} bytes")


def close_client(proc):
    if proc.stdin and not proc.stdin.closed:
        proc.stdin.write(b"QUIT\n")
        proc.stdin.flush()
        proc.stdin.close()
    status = proc.wait(timeout=5)
    assert status == 0, status


def main():
    with tempfile.TemporaryDirectory(prefix="vfs491d-test-") as tmp:
        socket_path = Path(tmp) / "control.sock"
        pid_file = Path(tmp) / "bridge-hung.pid"
        env = os.environ.copy()
        env.update(
            {
                "VFS491D_TEST_MODE": "1",
                "VFS491D_SOCKET": str(socket_path),
                "VFS491_BRIDGE_BIN": str(FAKE_BRIDGE),
                "VFS491_HELPER_BIN": "/dev/null",
                "VFS491_TEST_HANG_ONCE_FILE": str(pid_file),
            }
        )
        proc = subprocess.Popen([sys.executable, str(DAEMON), "--socket", str(socket_path)], env=env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline and not socket_path.exists():
                if proc.poll() is not None:
                    stderr = proc.stderr.read().decode(errors="replace") if proc.stderr else ""
                    raise RuntimeError(f"daemon exited early: {proc.returncode}\n{stderr}")
                time.sleep(0.05)
            assert socket_path.exists(), "daemon socket did not appear"

            # Killing the per-claim proxy during a running bridge must terminate
            # only that capture child and leave the boot-resident broker alive.
            cancelled_client = connect_client(socket_path, env)
            assert cancelled_client.stdin is not None
            cancelled_client.stdin.write(b"CAPTURE\n")
            cancelled_client.stdin.flush()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not pid_file.exists():
                time.sleep(0.05)
            assert pid_file.exists(), "fake bridge did not enter its hanging state"
            hung_pid = int(pid_file.read_text())
            cancelled_client.kill()
            cancelled_client.wait(timeout=5)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and Path(f"/proc/{hung_pid}").exists():
                time.sleep(0.05)
            assert not Path(f"/proc/{hung_pid}").exists(), "broker did not terminate capture after client disconnect"
            assert proc.poll() is None, "daemon exited when a capture client disconnected"
            print("PASS: client disconnect terminates active helper without stopping broker")

            second = connect_client(socket_path, env)
            capture(second, 1)
            capture(second, 2)
            close_client(second)
            assert proc.poll() is None, "daemon exited when the second fprintd client closed"

            third = connect_client(socket_path, env)
            capture(third, 3)
            close_client(third)
            assert proc.poll() is None, "daemon exited when the third fprintd client closed"
            print("PASS: TOD client proxy and vendor broker persist across independent claims")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)
            if proc.stderr:
                proc.stderr.close()


if __name__ == "__main__":
    main()
