#!/usr/bin/env python3
import importlib.util
import math
import os
import struct
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "vfs491_image_diagnostics", ROOT / "scripts" / "vfs491-image-diagnostics.py"
)
mod = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(mod)


class ImageDiagnosticsTests(unittest.TestCase):
    def test_parse_valid_frame(self):
        pixels = bytes(range(200))
        frame = struct.pack("<IIIII", mod.MAGIC, mod.VERSION, 200, 1, 200) + pixels
        width, height, got = mod.parse_frame(frame)
        self.assertEqual((width, height, got), (200, 1, pixels))

    def test_rejects_invalid_frame_length(self):
        frame = struct.pack("<IIIII", mod.MAGIC, mod.VERSION, 200, 3, 601) + b"x" * 601
        with self.assertRaises(ValueError):
            mod.parse_frame(frame)

    def test_constant_image_statistics(self):
        metrics = mod.image_metrics(4, 3, bytes([90] * 12))
        self.assertEqual(metrics["min"], 90)
        self.assertEqual(metrics["max"], 90)
        self.assertEqual(metrics["mean"], 90.0)
        self.assertEqual(metrics["stddev"], 0.0)
        self.assertEqual(metrics["entropy_bits"], 0.0)

    def test_gradient_metrics_are_finite(self):
        pixels = bytes((x * 20 + y * 5) % 256 for y in range(8) for x in range(6))
        metrics = mod.image_metrics(6, 8, pixels)
        for key in ("stddev", "entropy_bits", "horizontal_gradient_mean", "vertical_gradient_mean"):
            self.assertTrue(math.isfinite(metrics[key]))
        self.assertGreater(metrics["horizontal_gradient_mean"], 0)
        self.assertGreater(metrics["vertical_gradient_mean"], 0)

    def test_rejects_bad_pixel_buffer(self):
        with self.assertRaises(ValueError):
            mod.image_metrics(4, 4, b"too short")

    def test_pgm_writer_creates_private_file(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            path = Path(mod.write_pgm(folder, 1, 2, 2, bytes([1, 2, 3, 4])))
            self.assertEqual(path.read_bytes(), b"P5\n2 2\n255\n\x01\x02\x03\x04")
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main(verbosity=2)
