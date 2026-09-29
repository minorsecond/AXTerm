#!/usr/bin/env python3
"""Decode every frame from both feeds with Direwolf's decode_aprs.

Neither feed carries a decode: APRS-IS is raw TNC2 text and our database keeps
the bytes. To ask whether AXTerm reads them correctly, something that is not
AXTerm has to say what they mean first. decode_aprs is Direwolf's own parser,
the same one the on-air fixtures are checked against.
"""
import argparse, json, subprocess, re, os, sqlite3, datetime, collections

ap = argparse.ArgumentParser()
ap.add_argument("--capture", required=True)
ap.add_argument("--db", default=os.path.expanduser(
    "~/Library/Containers/com.rosswardrup.AXTerm/Data/Library/"
    "Application Support/AXTerm/axterm.sqlite"))
ap.add_argument("--out", required=True)
args = ap.parse_args()

ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
POS = re.compile(r"([NS]) (\d+) ([\d.]+), ([EW]) (\d+) ([\d.]+)")

def decode(lines):
    """name -> Direwolf's lines, by running one batch through decode_aprs."""
    text = "".join(l + "\n" for l in lines)
    out = subprocess.run(["decode_aprs"], input=text.encode("latin-1"),
                         capture_output=True, cwd=os.path.expanduser("~/dev/direwolf/data"))
    clean = ANSI.sub("", out.stdout.decode("latin-1"))
    blocks, current = [], []
    for ln in clean.splitlines():
        if not ln.strip():
            if current:
                blocks.append(current); current = []
            continue
        current.append(ln.rstrip())
    if current:
        blocks.append(current)
    return blocks

def position(block):
    for ln in block:
        m = POS.search(ln)
        if m:
            lat = (float(m.group(2)) + float(m.group(3)) / 60) * (-1 if m.group(1) == "S" else 1)
            lon = (float(m.group(5)) + float(m.group(6)) / 60) * (-1 if m.group(4) == "W" else 1)
            return round(lat, 6), round(lon, 6)
    return None

# ------------------------------------------------------------- both feeds
meta, is_frames = {}, []
for line in open(args.capture):
    d = json.loads(line)
    if d["kind"] == "meta":
        meta.update(d)
    elif d["kind"] == "frame":
        is_frames.append(d)
start = meta["started_epoch"]
end = meta.get("ended_epoch") or start + meta["seconds"]
fmt = lambda e: datetime.datetime.utcfromtimestamp(e).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]

con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
rows = con.execute("""
    SELECT receivedAt, fromCall, fromSSID, toCall, toSSID, viaPath, infoHex, radioID
    FROM packets WHERE direction='rx' AND receivedAt >= ? AND receivedAt <= ? AND pid = 240
    ORDER BY receivedAt""", (fmt(start), fmt(end))).fetchall()

records = []
for at, call, ssid, to, tossid, via, hex_, radio in rows:
    src = call if ssid == 0 else f"{call}-{ssid}"
    dest = to if tossid == 0 else f"{to}-{tossid}"
    info = bytes.fromhex(hex_).decode("latin-1").rstrip("\r\n")
    # decode_aprs wants TNC2: SRC>DEST[,path]:info — the AX.25 destination
    # matters, it is where a Mic-E frame keeps its latitude.
    tnc2 = f"{src}>{dest}" + (f",{via}" if via else "") + f":{info}"
    records.append({"feed": "rf", "at": at, "src": src, "dest": dest, "via": via,
                    "info": info, "hex": hex_, "radio": radio, "tnc2": tnc2})

for f in is_frames:
    text = f["text"]
    if ">" not in text or ":" not in text:
        continue
    head, info = text.split(":", 1)
    src = head.split(">", 1)[0]
    # The hex must be the information field alone. The capture records the
    # whole TNC2 line, and handing that to a parser expecting an info field
    # makes every frame look like one we failed to decode.
    # decode_aprs parses a TNC2 line as AX.25, so it rejects the whole frame
    # when the path holds an APRS-IS server name longer than a callsign
    # ("T2ALBERTA"). That is a property of the q-construct, not of the frame,
    # so the construct and everything after it comes off before decoding.
    path = head.split(">", 1)[1]
    qcut = re.search(r",q[A-Z][A-Za-z],", path + ",")
    if qcut:
        path = path[:qcut.start()]
    tnc2 = f"{src}>{path}:{info}"
    records.append({"feed": "is", "at": fmt(f["epoch"]), "src": src,
                    "dest": head.split(">", 1)[1].split(",")[0],
                    "via": head.split(">", 1)[1], "info": info,
                    "hex": info.encode("latin-1").hex(), "radio": "", "tnc2": tnc2})

blocks = decode([r["tnc2"] for r in records])
if len(blocks) != len(records):
    print(f"WARNING: {len(records)} frames in, {len(blocks)} decode blocks out")
for r, b in zip(records, blocks):
    r["direwolf"] = b[1:] if b else []
    r["position"] = position(b)

json.dump({"window": [fmt(start), fmt(end)], "records": records}, open(args.out, "w"), indent=1)
n_rf = sum(1 for r in records if r["feed"] == "rf")
print(f"{n_rf} RF + {len(records) - n_rf} APRS-IS frames decoded -> {args.out}")
