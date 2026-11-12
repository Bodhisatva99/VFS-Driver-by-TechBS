#!/usr/bin/env python3
import os
import time

raw = bytearray()
while len(raw) < 12:
    chunk = os.read(0, 12 - len(raw))
    if not chunk:
        raise SystemExit(90)
    raw.extend(chunk)

pid_file = os.environ.get("VFS491_TEST_CHILD_PID_FILE")
if pid_file:
    with open(pid_file, "w", encoding="ascii") as stream:
        stream.write(str(os.getpid()))

time.sleep(60)
