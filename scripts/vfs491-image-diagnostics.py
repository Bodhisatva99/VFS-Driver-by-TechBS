#!/usr/bin/env python3
"""Collect local VFS491 swipe-image quality metrics without exporting images.

Raw PGM images are written only when --save-images is explicitly supplied.
The output directory and files are restricted to the invoking root account.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import socket
import statistics
import struct
import sys
import time
from pathlib import Path
from typing import Any

SOCKET_PATH = "/var/lib/vfs491/control.sock"
HEADER = struct.Struct("<IIIII")
MAGIC = 0x31534656
VERSION = 1
WIDTH = 200
MAX_HEIGHT = 1023
MAX_FRAME = HEADER.size + WIDTH * MAX_HEIGHT


def read_line(sock: socket.socket, timeout: float, label: str) -> str:
    deadline = time.monotonic() + timeout
    data = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for {label}")
        sock.settimeout(remaining)
        byte = sock.recv(1)
        if not byte:
            raise RuntimeError(f"broker closed while waiting for {label}")
        if byte == b"\n":
            return data.decode("ascii", "strict").rstrip("\r")
        data.extend(byte)
        if len(data) > 128:
            raise RuntimeError("broker protocol line exceeded 128 bytes")


def read_exact(sock: socket.socket, length: int, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    data = bytearray()
    while len(data) < length:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"frame read timed out ({len(data)}/{length} bytes)")
        sock.settimeout(remaining)
        chunk = sock.recv(min(65536, length - len(data)))
        if not chunk:
            raise RuntimeError(f"broker closed during frame ({len(data)}/{length} bytes)")
        data.extend(chunk)
    return bytes(data)


def parse_frame(frame: bytes) -> tuple[int, int, bytes]:
    if len(frame) < HEADER.size or len(frame) > MAX_FRAME:
        raise ValueError(f"invalid frame size {len(frame)}")
    magic, version, width, height, image_len = HEADER.unpack_from(frame)
    if magic != MAGIC or version != VERSION:
        raise ValueError("invalid VFS491 frame magic or version")
    if width != WIDTH or not (1 <= height <= MAX_HEIGHT):
        raise ValueError(f"unsupported image dimensions {width}x{height}")
    if image_len != width * height or len(frame) != HEADER.size + image_len:
        raise ValueError("image payload length does not match dimensions")
    return width, height, frame[HEADER.size:]


def percentile(histogram: list[int], count: int, fraction: float) -> int:
    target = max(0, math.ceil(count * fraction) - 1)
    seen = 0
    for value, occurrences in enumerate(histogram):
        seen += occurrences
        if seen > target:
            return value
    return 255


def image_metrics(width: int, height: int, pixels: bytes) -> dict[str, Any]:
    if width <= 0 or height <= 0 or len(pixels) != width * height:
        raise ValueError("pixel buffer does not match image dimensions")

    histogram = [0] * 256
    total = 0
    squares = 0
    minimum = 255
    maximum = 0
    dark = 0
    bright = 0
    for value in pixels:
        histogram[value] += 1
        total += value
        squares += value * value
        minimum = min(minimum, value)
        maximum = max(maximum, value)
        dark += value <= 15
        bright += value >= 240

    count = len(pixels)
    mean = total / count
    variance = max(0.0, squares / count - mean * mean)
    entropy = -sum((n / count) * math.log2(n / count)
                   for n in histogram if n)

    row_means = [sum(pixels[y * width:(y + 1) * width]) / width
                 for y in range(height)]
    col_means = [sum(pixels[y * width + x] for y in range(height)) / height
                 for x in range(width)]

    horizontal_delta = 0
    vertical_delta = 0
    for y in range(height):
        row = y * width
        for x in range(1, width):
            horizontal_delta += abs(pixels[row + x] - pixels[row + x - 1])
    for y in range(1, height):
        row = y * width
        previous = row - width
        for x in range(width):
            vertical_delta += abs(pixels[row + x] - pixels[previous + x])

    horizontal_pairs = height * max(0, width - 1)
    vertical_pairs = max(0, height - 1) * width
    return {
        "width": width,
        "height": height,
        "bytes": count,
        "min": minimum,
        "p05": percentile(histogram, count, 0.05),
        "p50": percentile(histogram, count, 0.50),
        "p95": percentile(histogram, count, 0.95),
        "max": maximum,
        "mean": round(mean, 3),
        "stddev": round(math.sqrt(variance), 3),
        "entropy_bits": round(entropy, 3),
        "dark_pct": round(100 * dark / count, 3),
        "bright_pct": round(100 * bright / count, 3),
        "row_mean_stddev": round(statistics.pstdev(row_means), 3) if len(row_means) > 1 else 0.0,
        "column_mean_stddev": round(statistics.pstdev(col_means), 3) if len(col_means) > 1 else 0.0,
        "horizontal_gradient_mean": round(horizontal_delta / horizontal_pairs, 3) if horizontal_pairs else 0.0,
        "vertical_gradient_mean": round(vertical_delta / vertical_pairs, 3) if vertical_pairs else 0.0,
    }


def capture(sock: socket.socket, number: int, timeout: int) -> tuple[int, int, bytes, float]:
    started = time.monotonic()
    print(f"Swipe {number}: use the same enrolled finger, one continuous swipe", flush=True)
    sock.sendall(b"CAPTURE\n")
    response = read_line(sock, timeout + 20, "capture response")
    if response.startswith("ERR "):
        raise RuntimeError(f"broker capture failed with status {response[4:]}")
    if not response.startswith("OK "):
        raise RuntimeError(f"unexpected broker response: {response!r}")
    try:
        frame_size = int(response[3:])
    except ValueError as exc:
        raise RuntimeError("malformed frame length response") from exc
    if not (HEADER.size <= frame_size <= MAX_FRAME):
        raise RuntimeError(f"frame length outside bounds: {frame_size}")
    frame = read_exact(sock, frame_size, 20)
    width, height, pixels = parse_frame(frame)
    return width, height, pixels, time.monotonic() - started


def write_pgm(directory: Path, index: int, width: int, height: int, pixels: bytes) -> str:
    path = directory / f"swipe-{index:02d}.pgm"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(f"P5\n{width} {height}\n255\n".encode("ascii"))
        stream.write(pixels)
    return str(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=6, choices=range(3, 13),
                        help="number of same-finger swipe samples (default: 6)")
    parser.add_argument("--timeout", type=int, default=110)
    parser.add_argument("--save-images", metavar="NEW_DIRECTORY",
                        help="explicitly save raw PGM biometric images in a new private directory")
    parser.add_argument("--json-out", metavar="FILE", help="write metrics JSON to this file")
    parser.add_argument("--socket", default=SOCKET_PATH)
    args = parser.parse_args()

    if os.geteuid() != 0:
        raise SystemExit("Run with sudo: sudo python3 scripts/vfs491-image-diagnostics.py")

    image_dir: Path | None = None
    if args.save_images:
        image_dir = Path(args.save_images).expanduser()
        image_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
        os.chmod(image_dir, 0o700)

    results: list[dict[str, Any]] = []
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(15)
        sock.connect(args.socket)
        ready = read_line(sock, 15, "broker READY")
        if ready != "READY":
            raise RuntimeError(f"unexpected broker greeting: {ready!r}")

        for index in range(1, args.samples + 1):
            width, height, pixels, elapsed = capture(sock, index, args.timeout)
            entry = image_metrics(width, height, pixels)
            entry["capture_seconds"] = round(elapsed, 3)
            if image_dir is not None:
                entry["local_image"] = write_pgm(image_dir, index, width, height, pixels)
            results.append(entry)
            print(json.dumps({"sample": index, **entry}, sort_keys=True), flush=True)
        sock.sendall(b"QUIT\n")
    finally:
        sock.close()

    report = {
        "driver": "VFS491",
        "purpose": "capture image diagnostics; not a matcher or liveness test",
        "samples": results,
        "height_range": [min(x["height"] for x in results), max(x["height"] for x in results)],
        "stddev_range": [min(x["stddev"] for x in results), max(x["stddev"] for x in results)],
        "saved_raw_images": bool(image_dir),
        "raw_image_directory": str(image_dir) if image_dir else None,
    }
    output = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.json_out:
        out = Path(args.json_out).expanduser()
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(out, flags, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(output)
    print(output, end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, TimeoutError, ValueError) as exc:
        print(f"VFS491 image diagnostics: {exc}", file=sys.stderr)
        raise SystemExit(1)
