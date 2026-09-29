"""Measure the set at the size the map actually draws it.

Legibility at 18px is not an opinion: it is ink coverage (too little vanishes,
too much blobs) and silhouette distinctiveness (two icons that overlap almost
completely ARE the same icon to a reader). Both are measurable.
"""
import glob, os, subprocess, zlib, itertools, sys

N = 18   # the real glyph edge: a 22pt dot at 80%

def png_alpha(path):
    """Minimal RGBA8 PNG reader — alpha plane only, no dependencies."""
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n"
    i, idat, w, h = 8, b"", 0, 0
    while i < len(d):
        ln = int.from_bytes(d[i:i+4], "big"); typ = d[i+4:i+8]
        body = d[i+8:i+8+ln]; i += 12 + ln
        if typ == b"IHDR":
            w = int.from_bytes(body[0:4], "big"); h = int.from_bytes(body[4:8], "big")
            assert body[8] == 8 and body[9] == 6, "want RGBA8"
        elif typ == b"IDAT": idat += body
        elif typ == b"IEND": break
    raw = zlib.decompress(idat)
    bpp, stride = 4, w * 4
    out, prev, pos = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos+stride]); pos += stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out.append([line[x*4+3] for x in range(w)])
        prev = line
    return out

files = sorted(f for f in glob.glob("*.svg") if not f.startswith("_") and "colour" not in f)
masks = {}
for f in files:
    tmp = "/tmp/_m.png"
    subprocess.run(["rsvg-convert", "-w", str(N), "-h", str(N), f, "-o", tmp], check=True)
    a = png_alpha(tmp)
    masks[f[:-4]] = [1 if v >= 128 else 0 for row in a for v in row]
os.path.exists("/tmp/_m.png") and os.remove("/tmp/_m.png")

total = N * N
print("=== ink coverage at %dpx (the map's real glyph size) ===" % N)
ink = sorted(((sum(m) / total, k) for k, m in masks.items()))
for frac, k in ink[:5]:
    print("  LIGHTEST %-18s %5.1f%%" % (k, frac * 100))
print("  ...")
for frac, k in ink[-4:]:
    print("  heaviest %-18s %5.1f%%" % (k, frac * 100))
median = ink[len(ink)//2][0]
print("  median %.1f%%" % (median * 100))

print()
print("=== most confusable pairs (intersection over union of silhouettes) ===")
pairs = []
for a, b in itertools.combinations(sorted(masks), 2):
    ma, mb = masks[a], masks[b]
    inter = sum(1 for x, y in zip(ma, mb) if x and y)
    union = sum(1 for x, y in zip(ma, mb) if x or y)
    if union: pairs.append((inter / union, a, b))
pairs.sort(reverse=True)
for iou, a, b in pairs[:10]:
    print("  %.2f  %-18s %s" % (iou, a, b))
