#!/usr/bin/env python3
import struct
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
proc = subprocess.Popen(
    [sys.executable, str(root / "tests/fake-session.py")],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
assert proc.stdout is not None and proc.stdin is not None

ready = proc.stdout.readline().decode().rstrip("\n")
assert ready == "READY", ready

for index in range(3):
    proc.stdin.write(b"CAPTURE\n")
    proc.stdin.flush()
    record = proc.stdout.readline().decode().strip()
    assert record.startswith("OK "), record
    size = int(record.split()[1])
    frame = proc.stdout.read(size)
    assert len(frame) == size, (len(frame), size)
    magic, version, width, height, image_len = struct.unpack("<IIIII", frame[:20])
    assert magic == 0x31534656
    assert version == 1
    assert width == 200
    assert height == 347
    assert image_len == width * height
    assert len(frame) == 20 + image_len
    print(f"PASS: session capture {index + 1} returned {width}x{height}, {image_len} bytes")

proc.stdin.write(b"QUIT\n")
proc.stdin.flush()
proc.stdin.close()
status = proc.wait(timeout=5)
assert status == 0, status
print("PASS: one session handled multiple capture requests and closed cleanly")
