#!/usr/bin/env python3
import struct
import sys

MAGIC = 0x31534656
VERSION = 1
WIDTH = 200
HEIGHT = 347
pixels = bytes((i % 256 for i in range(WIDTH * HEIGHT)))
frame = struct.pack("<IIIII", MAGIC, VERSION, WIDTH, HEIGHT, len(pixels)) + pixels

sys.stdout.write("READY\n")
sys.stdout.flush()

for command in sys.stdin:
    command = command.rstrip("\n")
    if command == "QUIT":
        break
    if command != "CAPTURE":
        sys.stdout.write("ERR 12\n")
        sys.stdout.flush()
        continue
    sys.stdout.write(f"OK {len(frame)}\n")
    sys.stdout.flush()
    sys.stdout.buffer.write(frame)
    sys.stdout.buffer.flush()
