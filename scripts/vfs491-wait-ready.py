#!/usr/bin/python3
"""Wait for the VFS491 broker's real Unix-socket protocol readiness."""
from __future__ import annotations

import errno
import os
import socket
import sys
import time

SOCKET_PATH = os.environ.get("VFS491D_SOCKET", "/var/lib/vfs491/control.sock")
TIMEOUT = float(os.environ.get("VFS491_READY_TIMEOUT_SEC", "55"))
RETRYABLE = {errno.ENOENT, errno.ECONNREFUSED, errno.ECONNRESET, errno.ETIMEDOUT}


def log(message: str) -> None:
    print(f"vfs491-wait-ready: {message}", file=sys.stderr, flush=True)


def probe() -> bool:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(2.0)
        conn.connect(SOCKET_PATH)
        response = bytearray()
        while b"\n" not in response and len(response) <= 64:
            chunk = conn.recv(64)
            if not chunk:
                break
            response.extend(chunk)
        line = bytes(response).split(b"\n", 1)[0].strip()
        if line != b"READY":
            raise RuntimeError(f"broker returned unexpected readiness greeting: {line!r}")
        conn.sendall(b"QUIT\n")
        return True


def main() -> int:
    deadline = time.monotonic() + max(1.0, TIMEOUT)
    last_error: OSError | None = None
    while time.monotonic() < deadline:
        try:
            probe()
            log(f"broker is accepting clients at {SOCKET_PATH}")
            return 0
        except OSError as exc:
            last_error = exc
            if exc.errno not in RETRYABLE and not isinstance(exc, TimeoutError):
                log(f"readiness probe failed: {exc}")
                return 1
        except RuntimeError as exc:
            log(str(exc))
            return 1
        time.sleep(0.25)
    log(f"broker did not become ready within {TIMEOUT:.1f}s; last error: {last_error}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
