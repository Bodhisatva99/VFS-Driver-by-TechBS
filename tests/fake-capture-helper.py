#!/usr/bin/env python3
import os
import struct
import sys

raw = bytearray()
while len(raw) < 12:
    chunk = os.read(0, 12 - len(raw))
    if not chunk:
        raise SystemExit(90)
    raw.extend(chunk)
ready_fd, meta_fd, image_fd = struct.unpack("=iii", raw)
width, height = 200, 73
pixels = bytes((x * 3 + y * 7) & 0xFF for y in range(height) for x in range(width))
os.write(1, b"fake helper: initialized\n")
os.write(ready_fd, struct.pack("=Q", 0xAAAAAAAAAAAAAAAA))
os.write(meta_fd, struct.pack("=iii", len(pixels), width, height))
for offset in range(0, len(pixels), 997):
    os.write(image_fd, pixels[offset:offset + 997])
for fd in (ready_fd, meta_fd, image_fd):
    os.close(fd)
