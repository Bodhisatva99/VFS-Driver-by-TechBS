#!/usr/bin/env python3
from __future__ import annotations

import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts" / "vfs491-wait-ready.py"


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="vfs491-ready-test-") as tmp:
        path = str(Path(tmp) / "control.sock")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
        received: list[bytes] = []

        def accept_probe() -> None:
            conn, _ = server.accept()
            with conn:
                conn.sendall(b"READY\n")
                data = bytearray()
                while b"\n" not in data:
                    chunk = conn.recv(32)
                    if not chunk:
                        break
                    data.extend(chunk)
                received.append(bytes(data))

        thread = threading.Thread(target=accept_probe, daemon=True)
        thread.start()
        env = os.environ.copy()
        env.update({"VFS491D_SOCKET": path, "VFS491_READY_TIMEOUT_SEC": "2"})
        result = subprocess.run([sys.executable, str(PROBE)], env=env,
                                text=True, capture_output=True, timeout=5)
        thread.join(timeout=2)
        server.close()
        assert result.returncode == 0, result.stderr
        assert received == [b"QUIT\n"], received
        print("PASS: systemd readiness probe verifies READY and closes only its probe client")

        missing = str(Path(tmp) / "not-created.sock")
        env.update({"VFS491D_SOCKET": missing, "VFS491_READY_TIMEOUT_SEC": "0.6"})
        result = subprocess.run([sys.executable, str(PROBE)], env=env,
                                text=True, capture_output=True, timeout=3)
        assert result.returncode != 0, "missing broker must fail readiness" 
        assert "did not become ready" in result.stderr, result.stderr
        print("PASS: readiness probe fails within its deadline when broker is absent")


if __name__ == "__main__":
    main()
