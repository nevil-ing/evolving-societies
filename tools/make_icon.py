#!/usr/bin/env python3
"""Generate a crisp 1024x1024 RGBA PNG app icon for Evolving Societies.

Uses only the Python standard library so packaging requires zero extra packages.
"""

import math
import struct
import sys
import zlib


def write_png(path: str, width: int, height: int, rgba: bytes) -> None:
    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)  # filter type 0
        raw.extend(rgba[y * stride : (y + 1) * stride])

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(chunk(b"IHDR", ihdr))
        fh.write(chunk(b"IDAT", zlib.compress(bytes(raw), 6)))
        fh.write(chunk(b"IEND", b""))


def sd_rounded_box(px: float, py: float, bx: float, by: float, r: float) -> float:
    qx = abs(px) - bx + r
    qy = abs(py) - by + r
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


def sd_equilateral_triangle(px: float, py: float, r: float) -> float:
    k = math.sqrt(3.0)
    px = abs(px) - r
    py = py + r / k
    if px + k * py > 0.0:
        px, py = (px - k * py) * 0.5, (-k * px - py) * 0.5
    px -= max(-2.0 * r, min(0.0, px))
    return -math.hypot(px, py) * (1.0 if py >= 0.0 else -1.0)


def sd_segment(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
    pax, pay = px - ax, py - ay
    bax, bay = bx - ax, by - ay
    h = max(0.0, min(1.0, (pax * bax + pay * bay) / (bax * bax + bay * bay + 1e-9)))
    return math.hypot(pax - bax * h, pay - bay * h)


def clamp(v: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return lo if v < lo else hi if v > hi else v


def smoothstep(e0: float, e1: float, x: float) -> float:
    t = clamp((x - e0) / (e1 - e0))
    return t * t * (3.0 - 2.0 * t)


def main() -> None:
    out_path = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png"
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 512

    # Normalized coordinates [-1, 1] with macOS icon safe inset.
    # Three societies positioned in a balanced triad:
    # Triangles (top-left crimson), Circles (top-right blue), Squares (bottom emerald).
    tri_c = (-0.30, -0.22)
    cir_c = (0.30, -0.22)
    sq_c = (0.00, 0.30)

    buf = bytearray(size * size * 4)
    inv = 2.0 / size

    for y in range(size):
        ny = (y + 0.5) * inv - 1.0
        row_off = y * size * 4
        for x in range(size):
            nx = (x + 0.5) * inv - 1.0

            # macOS rounded icon mask
            d_box = sd_rounded_box(nx, ny, 0.86, 0.86, 0.22)
            mask = 1.0 - smoothstep(-0.006, 0.006, d_box)
            if mask <= 0.001:
                continue

            # Deep cosmic slate gradient background
            rad = math.hypot(nx, ny)
            r = 16.0 + 16.0 * (1.0 - clamp(rad))
            g = 20.0 + 18.0 * (1.0 - clamp(rad))
            b = 34.0 + 28.0 * (1.0 - clamp(rad))

            # Subtle inner rim highlight
            rim = smoothstep(-0.04, -0.008, d_box) * (1.0 - smoothstep(-0.008, 0.004, d_box))
            r += rim * 42.0
            g += rim * 52.0
            b += rim * 78.0

            # Soft society pheromone glows
            dt = math.hypot(nx - tri_c[0], ny - tri_c[1])
            dc = math.hypot(nx - cir_c[0], ny - cir_c[1])
            ds = math.hypot(nx - sq_c[0], ny - sq_c[1])

            gt = math.exp(-dt * dt * 5.2)
            gc = math.exp(-dc * dc * 5.2)
            gs = math.exp(-ds * ds * 5.2)

            r += gt * 125.0 + gc * 35.0 + gs * 30.0
            g += gt * 34.0 + gc * 70.0 + gs * 115.0
            b += gt * 38.0 + gc * 145.0 + gs * 68.0

            # Faint neural/communication ring & triad links connecting the three societies
            d_ring = abs(math.hypot(nx, ny - 0.02) - 0.44)
            ring = math.exp(-d_ring * d_ring * 2200.0) * 0.35
            d_l1 = sd_segment(nx, ny, tri_c[0], tri_c[1], cir_c[0], cir_c[1])
            d_l2 = sd_segment(nx, ny, cir_c[0], cir_c[1], sq_c[0], sq_c[1])
            d_l3 = sd_segment(nx, ny, sq_c[0], sq_c[1], tri_c[0], tri_c[1])
            link = math.exp(-min(d_l1, d_l2, d_l3) ** 2 * 3200.0) * 0.45
            r += (ring + link) * 140.0
            g += (ring + link) * 175.0
            b += (ring + link) * 230.0

            # Central golden hybrid synapse spark
            d_hub = math.hypot(nx, ny - 0.02)
            hub = 1.0 - smoothstep(0.042, 0.056, d_hub)
            hub_glow = math.exp(-d_hub * d_hub * 80.0) * 0.55
            r += hub_glow * 255.0
            g += hub_glow * 220.0
            b += hub_glow * 90.0

            # 1. Crimson Triangle (pointing up)
            d_tri = sd_equilateral_triangle(nx - tri_c[0], -(ny - tri_c[1]) - 0.02, 0.165)
            tri_fill = 1.0 - smoothstep(-0.008, 0.008, d_tri)
            tri_rim = 1.0 - smoothstep(0.0, 0.016, abs(d_tri))

            # 2. Royal-blue Circle
            d_cir = dc - 0.155
            cir_fill = 1.0 - smoothstep(-0.008, 0.008, d_cir)
            cir_rim = 1.0 - smoothstep(0.0, 0.016, abs(d_cir))

            # 3. Emerald Square (rotated 45 deg diamond/square)
            sx, sy = nx - sq_c[0], ny - sq_c[1]
            rx = (sx + sy) * 0.70710678
            ry = (sy - sx) * 0.70710678
            d_sq = sd_rounded_box(rx, ry, 0.145, 0.145, 0.028)
            sq_fill = 1.0 - smoothstep(-0.008, 0.008, d_sq)
            sq_rim = 1.0 - smoothstep(0.0, 0.016, abs(d_sq))

            # Composite shapes cleanly over background
            if tri_fill > 0:
                r = r * (1 - tri_fill) + 255.0 * tri_fill
                g = g * (1 - tri_fill) + 92.0 * tri_fill
                b = b * (1 - tri_fill) + 84.0 * tri_fill
            if cir_fill > 0:
                r = r * (1 - cir_fill) + 92.0 * cir_fill
                g = g * (1 - cir_fill) + 148.0 * cir_fill
                b = b * (1 - cir_fill) + 255.0 * cir_fill
            if sq_fill > 0:
                r = r * (1 - sq_fill) + 92.0 * sq_fill
                g = g * (1 - sq_fill) + 232.0 * sq_fill
                b = b * (1 - sq_fill) + 128.0 * sq_fill

            # Crisp bright borders on shapes + golden center spark
            edge = max(tri_rim, cir_rim, sq_rim) * 0.45
            r = r * (1 - edge) + 255.0 * edge
            g = g * (1 - edge) + 255.0 * edge
            b = b * (1 - edge) + 255.0 * edge

            if hub > 0:
                r = r * (1 - hub) + 255.0 * hub
                g = g * (1 - hub) + 225.0 * hub
                b = b * (1 - hub) + 95.0 * hub

            idx = row_off + x * 4
            buf[idx] = int(clamp(r, 0.0, 255.0))
            buf[idx + 1] = int(clamp(g, 0.0, 255.0))
            buf[idx + 2] = int(clamp(b, 0.0, 255.0))
            buf[idx + 3] = int(clamp(mask * 255.0, 0.0, 255.0))

    write_png(out_path, size, size, bytes(buf))


if __name__ == "__main__":
    main()
