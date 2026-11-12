#!/usr/bin/env python3
import os
import struct
import sys
import time
from pathlib import Path

marker = os.environ.get("VFS491_TEST_HANG_ONCE_FILE")
if marker and not Path(marker).exists():
    Path(marker).write_text(str(os.getpid()))
    time.sleep(60)

width, height = 200, 2
pixels = bytes((i * 17) & 0xFF for i in range(width * height))
header = struct.pack("<IIIII", 0x31534656, 1, width, height, len(pixels))
sys.stdout.buffer.write(header + pixels)
