#!/usr/bin/env python3
import os
import sys

raw = bytearray()
while len(raw) < 12:
    chunk = os.read(0, 12 - len(raw))
    if not chunk:
        raise SystemExit(90)
    raw.extend(chunk)
os.write(1, b"SIGALRM caught: Timed out waiting for capture\n")
raise SystemExit(110)
