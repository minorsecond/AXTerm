"""Regenerate the app's asset catalog from these SVGs.

Run from the repo root: python3 Design/aprs-symbols/install.py
"""
import io, os, json, glob, shutil

SRC = os.path.dirname(os.path.abspath(__file__))
DST = os.path.join(SRC, "..", "..", "AXTerm", "Assets.xcassets", "APRSSymbols")
DST = os.path.normpath(DST)

if os.path.isdir(DST):
    shutil.rmtree(DST)
os.makedirs(DST)
io.open(os.path.join(DST, "Contents.json"), "w", encoding="utf-8").write(json.dumps(
    {"info": {"author": "xcode", "version": 1},
     "properties": {"provides-namespace": True}}, indent=2) + "\n")

names = sorted(os.path.basename(f)[:-4] for f in glob.glob(os.path.join(SRC, "*.svg"))
               if not os.path.basename(f).startswith("_"))
for n in names:
    d = os.path.join(DST, n + ".imageset")
    os.makedirs(d)
    shutil.copy(os.path.join(SRC, n + ".svg"), d)
    props = {"preserves-vector-representation": True}
    # The colour apple is artwork, not a mask: tinting it white would throw
    # away the only reason it exists.
    if not n.endswith("-colour"):
        props["template-rendering-intent"] = "template"
    io.open(os.path.join(d, "Contents.json"), "w", encoding="utf-8").write(json.dumps({
        "images": [{"filename": n + ".svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": props}, indent=2) + "\n")
print("%d imagesets -> %s" % (len(names), DST))
