#!/usr/bin/env python3
"""Validate Marquee app icon artwork fills the macOS icon canvas enough.

The Dock regression we are guarding against is not a missing icon slot. It is
an icon image with too much transparent padding, which macOS renders as a
visibly smaller Dock icon. This script inspects the alpha bounding box of the
source AppIcon PNGs and, when supplied, the exported app's compiled ICNS.
"""

from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from dataclasses import dataclass
from pathlib import Path


SOURCE_ICON_PATHS = (
    "Marquee-app-icon.png",
    "Marquee/Assets.xcassets/AppIcon.appiconset/icon_32x32.png",
    "Marquee/Assets.xcassets/AppIcon.appiconset/icon_128x128.png",
    "Marquee/Assets.xcassets/AppIcon.appiconset/icon_512x512.png",
    "Marquee/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png",
)


@dataclass(frozen=True)
class IconMetrics:
    path: Path
    width: int
    height: int
    bbox_width: int
    bbox_height: int
    pad_left: int
    pad_top: int
    pad_right: int
    pad_bottom: int

    @property
    def width_ratio(self) -> float:
        return self.bbox_width / self.width

    @property
    def height_ratio(self) -> float:
        return self.bbox_height / self.height

    def describe(self) -> str:
        return (
            f"{self.path}: {self.width}x{self.height} "
            f"bbox={self.bbox_width}x{self.bbox_height} "
            f"ratio={self.width_ratio:.1%}x{self.height_ratio:.1%} "
            f"pad={self.pad_left},{self.pad_top},{self.pad_right},{self.pad_bottom}"
        )


def paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def read_png_metrics(path: Path) -> IconMetrics:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")

    offset = 8
    width = height = bit_depth = color_type = None
    compressed = bytearray()
    while offset < len(data):
        chunk_length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data = data[offset + 8 : offset + 8 + chunk_length]
        offset += 12 + chunk_length
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _, _, _ = struct.unpack(">IIBBBBB", chunk_data)
        elif chunk_type == b"IDAT":
            compressed.extend(chunk_data)
        elif chunk_type == b"IEND":
            break

    if width is None or height is None or bit_depth is None or color_type is None:
        raise ValueError(f"{path} has no IHDR")
    if bit_depth != 8:
        raise ValueError(f"{path} uses unsupported bit depth {bit_depth}")
    if color_type != 6:
        raise ValueError(f"{path} uses unsupported PNG color type {color_type}; expected RGBA")

    raw = zlib.decompress(bytes(compressed))
    bytes_per_pixel = 4
    stride = width * bytes_per_pixel
    prior = bytearray(stride)
    pos = 0
    left = width
    top = height
    right = -1
    bottom = -1

    for y in range(height):
        filter_type = raw[pos]
        pos += 1
        row = bytearray(raw[pos : pos + stride])
        pos += stride

        for i in range(stride):
            a = row[i - bytes_per_pixel] if i >= bytes_per_pixel else 0
            b = prior[i]
            c = prior[i - bytes_per_pixel] if i >= bytes_per_pixel else 0
            if filter_type == 0:
                value = row[i]
            elif filter_type == 1:
                value = (row[i] + a) & 0xFF
            elif filter_type == 2:
                value = (row[i] + b) & 0xFF
            elif filter_type == 3:
                value = (row[i] + ((a + b) // 2)) & 0xFF
            elif filter_type == 4:
                value = (row[i] + paeth(a, b, c)) & 0xFF
            else:
                raise ValueError(f"{path} uses unsupported PNG filter {filter_type}")
            row[i] = value

        for x in range(width):
            alpha = row[x * bytes_per_pixel + 3]
            if alpha > 0:
                left = min(left, x)
                top = min(top, y)
                right = max(right, x)
                bottom = max(bottom, y)
        prior = row

    if right < left or bottom < top:
        raise ValueError(f"{path} has no visible icon artwork")

    return IconMetrics(
        path=path,
        width=width,
        height=height,
        bbox_width=right - left + 1,
        bbox_height=bottom - top + 1,
        pad_left=left,
        pad_top=top,
        pad_right=width - right - 1,
        pad_bottom=height - bottom - 1,
    )


def metrics_for_icns(icns_path: Path) -> IconMetrics:
    sips = shutil.which("sips")
    if sips is None:
        raise ValueError("sips is required to validate compiled AppIcon.icns")
    with tempfile.TemporaryDirectory(prefix="marquee-icon-") as tmp:
        png_path = Path(tmp) / "AppIcon.png"
        subprocess.run(
            [sips, "-s", "format", "png", str(icns_path), "--out", str(png_path)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        metrics = read_png_metrics(png_path)
        return IconMetrics(
            path=icns_path,
            width=metrics.width,
            height=metrics.height,
            bbox_width=metrics.bbox_width,
            bbox_height=metrics.bbox_height,
            pad_left=metrics.pad_left,
            pad_top=metrics.pad_top,
            pad_right=metrics.pad_right,
            pad_bottom=metrics.pad_bottom,
        )


def validate(metrics: IconMetrics, min_width_ratio: float, min_height_ratio: float) -> bool:
    return metrics.width_ratio >= min_width_ratio and metrics.height_ratio >= min_height_ratio


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", default=".", help="Repository root containing Marquee app icon PNGs")
    parser.add_argument("--app", help="Optional exported Marquee.app bundle to validate")
    parser.add_argument("--min-width-ratio", type=float, default=0.80)
    parser.add_argument("--min-height-ratio", type=float, default=0.80)
    args = parser.parse_args()

    failures: list[str] = []
    root = Path(args.source_root).resolve()
    for relative in SOURCE_ICON_PATHS:
        path = root / relative
        metrics = read_png_metrics(path)
        ok = validate(metrics, args.min_width_ratio, args.min_height_ratio)
        print(f"{'PASS' if ok else 'FAIL'} source {metrics.describe()}")
        if not ok:
            failures.append(metrics.describe())

    if args.app:
        icns_path = Path(args.app).resolve() / "Contents/Resources/AppIcon.icns"
        metrics = metrics_for_icns(icns_path)
        ok = validate(metrics, args.min_width_ratio, args.min_height_ratio)
        print(f"{'PASS' if ok else 'FAIL'} compiled {metrics.describe()}")
        if not ok:
            failures.append(metrics.describe())

    if failures:
        print(
            "verify-app-icon-geometry: outcome=failed "
            f"min={args.min_width_ratio:.0%}x{args.min_height_ratio:.0%} failures={len(failures)}",
            file=sys.stderr,
        )
        return 1

    print("verify-app-icon-geometry: outcome=verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
