"""Contact sheet for review: 4x grid, then the 26px size the map draws."""
import glob, io

SKIP = {"mac-apple-colour.svg"}   # a colour variant, not a set member
files = sorted(f for f in glob.glob("*.svg")
               if not f.startswith("_") and f not in SKIP)
cols, cell = 6, 110
rows = (len(files) + cols - 1) // cols
w, h = cols * cell, rows * (cell + 22) + 150
p = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">' % (w, h, w, h),
     '<rect width="%d" height="%d" fill="#111417"/>' % (w, h)]

def inner(f):
    return io.open(f, encoding="utf-8").read().split(">", 1)[1].rsplit("</svg>", 1)[0]

for i, f in enumerate(files):
    cx, cy = (i % cols) * cell, (i // cols) * (cell + 22)
    p.append('<g transform="translate(%d,%d) scale(4)" fill="#e8eef2" fill-rule="evenodd">%s</g>'
             % (cx + 7, cy + 7, inner(f)))
    p.append('<text x="%d" y="%d" fill="#7d8b95" font-family="Helvetica" font-size="11" '
             'text-anchor="middle">%s</text>' % (cx + cell // 2, cy + cell + 14, f[:-4]))

y0 = rows * (cell + 22) + 30
tints = ["#5c5c9e", "#337f8f", "#b8722f", "#6b7378"]
p.append('<text x="12" y="%d" fill="#7d8b95" font-family="Helvetica" font-size="11">'
         'on the map — 26px dot</text>' % (y0 - 12))
for i, f in enumerate(files):
    cx, yy = 14 + (i % 15) * 42, y0 + (i // 15) * 46
    p.append('<circle cx="%d" cy="%d" r="13" fill="%s"/>' % (cx + 13, yy + 13, tints[i % 4]))
    p.append('<g transform="translate(%s,%s) scale(0.866)" fill="#fff" fill-rule="evenodd">%s</g>'
             % (cx + 2.6, yy + 2.6, inner(f)))

y1 = y0 + 100
p.append('<text x="12" y="%d" fill="#7d8b95" font-family="Helvetica" font-size="11">'
         'the digipeater star carrying real overlays from the capture</text>' % (y1 - 12))
for i, ch in enumerate(["S", "1", "I", "D", "G", "2", "9"]):
    cx = 14 + i * 42
    p.append('<circle cx="%d" cy="%d" r="13" fill="#5c5c9e"/>' % (cx + 13, y1 + 13))
    p.append('<g transform="translate(%s,%s) scale(0.866)" fill="#fff" fill-rule="evenodd">%s</g>'
             % (cx + 2.6, y1 + 2.6, inner("digipeater.svg")))
    p.append('<text x="%d" y="%d" fill="#fff" font-family="Helvetica-Bold" font-size="13" '
             'text-anchor="middle">%s</text>' % (cx + 13, y1 + 18, ch))
p.append("</svg>")
io.open("_sheet.svg", "w", encoding="utf-8").write("\n".join(p))
