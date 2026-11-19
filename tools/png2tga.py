#!/usr/bin/env python3
"""Convert an RGBA/RGB PNG into square 32-bit TGA textures for WoW (pure Python, no dependencies).

Usage: python3 -I tools/png2tga.py <input.png> <output.tga> <size> [--circle]

Downscales by area averaging (alpha-weighted, so transparent pixels don't darken edges). The output size
must divide the source size evenly and be a power of two, which WoW requires for textures.
--circle makes everything outside the inscribed circle transparent, with an anti-aliased edge.
"""
import struct
import sys
import zlib


def read_png(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, header = 8, [], None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
    width, height, depth, color, _, _, interlace = header
    if depth != 8 or color not in (2, 6) or interlace != 0:
        raise ValueError("only 8-bit non-interlaced RGB/RGBA PNGs are supported")
    bpp = 4 if color == 6 else 3
    raw = zlib.decompress(b"".join(idat))
    stride = width * bpp
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(height):
        ftype = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        if ftype == 1:
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 0xFF
        elif ftype == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif ftype == 3:
            for x in range(stride):
                left = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((left + prev[x]) >> 1)) & 0xFF
        elif ftype == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 0xFF
        rows.append(bytes(line))
        prev = line
    if bpp == 3:
        rows = [b"".join(r[x:x + 3] + b"\xff" for x in range(0, stride, 3)) for r in rows]
    return width, height, rows


def downscale(width, height, rows, size):
    if width != height or width % size:
        raise ValueError("source must be square and a multiple of the output size")
    f = width // size
    out = []
    for oy in range(size):
        line = []
        for ox in range(size):
            r = g = b = a = 0
            for sy in range(oy * f, oy * f + f):
                row = rows[sy]
                for sx in range(ox * f * 4, (ox * f + f) * 4, 4):
                    pa = row[sx + 3]
                    r += row[sx] * pa
                    g += row[sx + 1] * pa
                    b += row[sx + 2] * pa
                    a += pa
            n = f * f
            if a:
                line.append((r // a, g // a, b // a, a // n))
            else:
                line.append((0, 0, 0, 0))
        out.append(line)
    return out


def circle_mask(pixels):
    size = len(pixels)
    c = size / 2.0
    radius = c - 0.5
    for y in range(size):
        for x in range(size):
            d = ((x + 0.5 - c) ** 2 + (y + 0.5 - c) ** 2) ** 0.5
            cover = max(0.0, min(1.0, radius - d + 0.5))
            r, g, b, a = pixels[y][x]
            pixels[y][x] = (r, g, b, int(a * cover))
    return pixels


def write_tga(path, pixels):
    size = len(pixels)
    # Uncompressed true-color, 32 bpp, 8 alpha bits, top-left origin (descriptor 0x28).
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 0x28)
    body = bytearray()
    for row in pixels:
        for r, g, b, a in row:
            body += bytes((b, g, r, a))
    with open(path, "wb") as f:
        f.write(header + bytes(body))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 3:
        sys.exit(__doc__)
    src, dst, size = args[0], args[1], int(args[2])
    if size & (size - 1):
        sys.exit("size must be a power of two")
    w, h, rows = read_png(src)
    pixels = downscale(w, h, rows, size)
    if "--circle" in sys.argv:
        pixels = circle_mask(pixels)
    write_tga(dst, pixels)
    print(f"{src} ({w}x{h}) -> {dst} ({size}x{size})")


if __name__ == "__main__":
    main()
