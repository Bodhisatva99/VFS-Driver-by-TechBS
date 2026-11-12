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
os.write(ready_fd, struct.pack("=Q", 0x123456789ABCDEF0))
for fd in (ready_fd, meta_fd, image_fd):
    os.close(fd)
raise SystemExit(0)
