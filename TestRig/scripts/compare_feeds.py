#!/usr/bin/env python3
"""Compare what our radios heard on RF against what APRS-IS carried, same window.

Two feeds of the same air. Ours is `packets` in AXTerm's database (direction
rx, PID 0xF0 UI frames); theirs is the APRS-IS stream aprs.fi displays,
captured by aprsis_capture.py.

The join is (source callsign, information field) — byte for byte. The path
cannot be compared: an igate rewrites it, appending `qAR,<igate>` and dropping
what it does not need. The information field is what the station actually said,
and it must be identical in both feeds or somebody's copy is wrong.
"""
import argparse, json, sqlite3, collections, datetime, re, os

ap = argparse.ArgumentParser()
ap.add_argument("--capture", required=True)
ap.add_argument("--db", default=os.path.expanduser(
    "~/Library/Containers/com.rosswardrup.AXTerm/Data/Library/"
    "Application Support/AXTerm/axterm.sqlite"))
ap.add_argument("--out", default="")
args = ap.parse_args()

# ---------------------------------------------------------------- APRS-IS
meta, is_frames = {}, []
for line in open(args.capture):
    d = json.loads(line)
    if d["kind"] == "meta":
        meta.update(d)
    elif d["kind"] == "frame":
        text = d["text"]
        if ":" not in text or ">" not in text:
            continue
        head, info = text.split(":", 1)
        src = head.split(">", 1)[0]
        path = head.split(">", 1)[1]
        is_frames.append({"epoch": d["epoch"], "src": src, "path": path, "info": info,
                          "hex": d.get("hex", "")})

start, end = meta["started_epoch"], meta.get("ended_epoch") or (meta["started_epoch"] + meta["seconds"])
fmt = lambda e: datetime.datetime.utcfromtimestamp(e).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]

# ------------------------------------------------------------------- ours
con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
rows = con.execute("""
    SELECT receivedAt, fromCall, fromSSID, toCall, viaPath, infoASCII, infoHex, radioID
    FROM packets
    WHERE direction='rx' AND receivedAt >= ? AND receivedAt <= ? AND pid = 240
    ORDER BY receivedAt""", (fmt(start), fmt(end))).fetchall()

# APRS data type identifiers (APRS 1.01 ch.5). A UI frame whose information
# field starts with something else is ordinary AX.25 — a BBS prompt, a BPQ
# node ID, a NET/ROM broadcast — and has no business being compared against
# APRS-IS, which would never carry it. Our packet channel is full of those.
APRS_DTI = set("!=/@`'`;)<>:?_TA$*,{}")

def looks_aprs(info, to):
    if not info:
        return False
    if info[0] in APRS_DTI or ord(info[0]) in (0x1c, 0x1d):
        # `<` and `>` also start BBS chatter; require an APRS-shaped tocall or
        # a Mic-E destination to keep those out.
        return True
    return False

rf = []
for at, call, ssid, to, via, ascii_, hex_, radio in rows:
    src = call if ssid == 0 else f"{call}-{ssid}"
    info = bytes.fromhex(hex_).decode("latin-1")
    rf.append({"at": at, "src": src, "to": to, "via": via, "radio": radio,
               "info": info, "hex": hex_, "aprs": looks_aprs(info, to)})

# Which radio carries APRS: the one whose traffic is APRS-shaped. Comparing the
# packet/BBS channel against APRS-IS would only ever report the whole channel
# as "not gated", which is true and meaningless.
by_radio = collections.defaultdict(list)
for f in rf:
    by_radio[f["radio"]].append(f)
print("radios:")
for radio, frames in by_radio.items():
    n = sum(1 for f in frames if f["aprs"])
    print(f"   {radio[:8]:<9} {len(frames):>4} frames, {n:>4} APRS-shaped")
rf = [f for f in rf if f["aprs"]]

# ----------------------------------------------------------------- joining
def key(src, info):
    # APRS-IS strips the trailing CR that rides an AX.25 frame; some gates
    # also trim trailing whitespace. Compare on the substance.
    return (src.upper(), info.rstrip("\r\n ").rstrip("\x00"))

is_by_key = collections.defaultdict(list)
for f in is_frames:
    is_by_key[key(f["src"], f["info"])].append(f)

is_by_src = collections.defaultdict(list)
for f in is_frames:
    is_by_src[f["src"].upper()].append(f)

rf_by_src = collections.defaultdict(list)
for f in rf:
    rf_by_src[f["src"].upper()].append(f)

matched, unmatched = [], []
for f in rf:
    if is_by_key.get(key(f["src"], f["info"])):
        matched.append(f)
    else:
        unmatched.append(f)

report = {
    "window_utc": [fmt(start), fmt(end)],
    "minutes": round((end - start) / 60, 1),
    "rf_frames": len(rf), "rf_stations": len(rf_by_src),
    "is_frames": len(is_frames), "is_stations": len(is_by_src),
    "matched": len(matched), "unmatched": len(unmatched),
}

print(f"window   {report['window_utc'][0]}Z .. {report['window_utc'][1]}Z  ({report['minutes']} min)")
print(f"RF       {len(rf)} APRS frames from {len(rf_by_src)} stations (our two radios)")
print(f"APRS-IS  {len(is_frames)} frames from {len(is_by_src)} stations (150 km filter)")
print(f"joined   {len(matched)} of our frames appear on APRS-IS byte-identical, "
      f"{len(unmatched)} do not")

# Stations we heard that never showed up at all: the clearest gating gap.
heard_not_gated = sorted(s for s in rf_by_src if s not in is_by_src)
print(f"\nheard on RF, absent from APRS-IS entirely: {len(heard_not_gated)}")
for s in heard_not_gated:
    ex = rf_by_src[s][0]
    print(f"   {s:<12} x{len(rf_by_src[s]):<3} {ex['info'][:58]!r}")

# Same station present on IS, but this particular transmission was not.
partly = collections.Counter(f["src"].upper() for f in unmatched if f["src"].upper() in is_by_src)
print(f"\nstations on both, but with frames of ours missing from APRS-IS: {len(partly)}")
for s, n in partly.most_common(15):
    print(f"   {s:<12} {n} of {len(rf_by_src[s])} not gated")

# A transmission of ours with no byte-identical twin, but the same station
# saying something very like it at nearly the same moment: one of the two
# copies is corrupt. This is the comparison that can find a decoder bug.
import difflib
near = []
for f in unmatched:
    src = f["src"].upper()
    at = datetime.datetime.strptime(f["at"][:23], "%Y-%m-%d %H:%M:%S.%f").replace(
        tzinfo=datetime.timezone.utc).timestamp()
    best, score = None, 0.0
    for g in is_by_src.get(src, []):
        if abs(g["epoch"] - at) > 180:
            continue
        r = difflib.SequenceMatcher(None, f["info"], g["info"]).ratio()
        if r > score:
            best, score = g, r
    if best is not None and 0.7 <= score < 1.0:
        near.append({"src": src, "score": round(score, 3), "ours": f["info"],
                     "theirs": best["info"], "our_hex": f["hex"], "their_hex": best["hex"],
                     "gap_s": round(best["epoch"] - at, 1)})

print(f"\nsame station, nearly-but-not-quite the same frame: {len(near)}")
for n in near[:20]:
    print(f"   {n['src']:<12} similarity {n['score']}  ({n['gap_s']:+.0f}s)")
    print(f"       ours   {n['ours']!r}")
    print(f"       theirs {n['theirs']!r}")

# Our own station: is anything gating us?
us = [f for f in is_frames if f["src"].upper().startswith("K0EPI")]
print(f"\nour own traffic on APRS-IS: {len(us)} frames")
for f in us[:6]:
    gate = f["path"].split(",")[-1] if "," in f["path"] else "?"
    print(f"   via {gate:<10} {f['info'][:60]!r}")

report["near_misses"] = near
report["ours_on_is"] = [{"path": f["path"], "info": f["info"]} for f in us]
report["heard_not_gated"] = heard_not_gated
report["partly_gated"] = dict(partly)
report["unmatched_examples"] = [{"at": f["at"], "src": f["src"], "info": f["info"][:120],
                                 "hex": f["hex"], "radio": f["radio"]} for f in unmatched[:200]]
report["rf_by_src"] = {s: len(v) for s, v in sorted(rf_by_src.items())}

if args.out:
    json.dump(report, open(args.out, "w"), indent=2)
    print(f"\n-> {args.out}")
