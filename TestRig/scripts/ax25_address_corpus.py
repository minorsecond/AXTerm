#!/usr/bin/env python3
"""Build AXTermTests/Fixtures/ax25-address-corpus.json.

Collects every distinct frame from an AXTerm packet database (opened
read-only), every frame_hex in the other fixtures, and a set of constructed
connected-mode, NET/ROM and edge-case frames. Each frame's expected fields
come from a transcription of the decoder as it was before the strict address
rules. A frame the rules would refuse is listed under "rejected" instead,
so a real station the rules would lose shows up here before it ships.

    python3 ax25_address_corpus.py [path/to/axterm.sqlite]
"""
import json, os, sqlite3, glob, re, sys
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DB = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
    "~/Library/Containers/com.rosswardrup.AXTerm/Data/tmp/AXTerm-Test/axterm-test-default.sqlite")

# ---- Old (pre-change) decoder, transcribed from KISSAX25Decoder.swift ----
def old_addr(b, off):
    if off + 7 > len(b): return None
    call = ""
    for i in range(6):
        c = b[off+i] >> 1
        if 0x20 <= c < 0x7F and c != 0x20: call += chr(c)
    call = call.strip().upper()
    if not call: return None
    s = b[off+6]
    return dict(call=call, ssid=(s >> 1) & 0x0F, rep=bool(s & 0x80), last=bool(s & 1))

def classify(c):
    if c & 1 == 0: return "I"
    if c & 3 == 1: return "S"
    if c & 0xEF == 0x03: return "UI"
    return "U"

def old_decode(b):
    if len(b) < 15: return None
    d = old_addr(b, 0); s = old_addr(b, 7)
    if not d or not s: return None
    via = []; off = 14; last = s["last"]
    while not last and off + 7 <= len(b) and len(via) < 8:
        v = old_addr(b, off)
        if not v: break
        via.append(v); off += 7; last = v["last"]
    if off >= len(b): return dict(unknown=True)
    ctl = b[off]; off += 1
    ft = classify(ctl); pid = None
    if ft in ("I", "UI") and off < len(b): pid = b[off]; off += 1
    disp = lambda a: a["call"] + (f"-{a['ssid']}" if a["ssid"] else "")
    return {"to": disp(d), "from": disp(s),
            "via": [disp(v) + ("*" if v["rep"] else "") for v in via],
            "control": ctl, "pid": pid, "frame_type": ft, "info_hex": b[off:].hex()}

# ---- Strict rules (independent oracle, for vetting the corpus) ----
def strict_ok(b):
    if len(b) < 15: return False
    n = 0; off = 0
    while True:
        if off + 7 > len(b) or n >= 10: return False
        for i in range(6):
            if b[off+i] & 1: return False
        s = "".join(chr(x >> 1) for x in b[off:off+6])
        if not re.fullmatch(r"[A-Z0-9]{1,6} *", s) or len(s) != 6: return False
        n += 1
        last = b[off+6] & 1
        off += 7
        if last:
            return n >= 2 and off < len(b)

# ---- AX.25 builders for constructed frames ----
def addr(call, ssid=0, last=False, hbit=False, reserved=0x60):
    call = call.ljust(6)
    out = bytes(ord(c) << 1 for c in call)
    s = reserved | ((ssid & 0xF) << 1) | (1 if last else 0) | (0x80 if hbit else 0)
    return out + bytes([s])

def frame(dest, src, via, ctl, pid=None, info=b"", cmd=True, reserved=0x60):
    # dest/src are (call, ssid); via is [(call, ssid, hbit)]
    out = addr(*dest, last=False, hbit=cmd, reserved=reserved)
    out += addr(*src, last=not via, hbit=not cmd, reserved=reserved)
    for i, (c, s, h) in enumerate(via):
        out += addr(c, s, last=(i == len(via) - 1), hbit=h, reserved=reserved)
    out += bytes([ctl])
    if pid is not None: out += bytes([pid])
    return out + info

corpus = []
seen = set()
def add(name, prov, raw):
    h = raw.hex()
    if h in seen: return
    seen.add(h)
    if not strict_ok(raw):
        print("NOT STRICT-VALID:", name, prov, h, file=sys.stderr); return
    exp = old_decode(raw)
    assert exp and "unknown" not in exp, (name, h)
    corpus.append({"name": name, "provenance": prov, "frame_hex": h, "expect": exp})

# 1. Live test database (overnight capture, 2026-09-29/30)
con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
rows = con.execute("select min(receivedAt), direction, fromCall, fromSSID, toCall, rawAx25Hex from packets group by rawAx25Hex order by min(receivedAt)").fetchall()
rejected = []
for (at, direction, fc, fs, tc, hx) in rows:
    raw = bytes.fromhex(hx)
    name = f"db {direction} {fc}{'-'+str(fs) if fs else ''}>{tc} {at}"
    if not strict_ok(raw):
        rejected.append((name, hx)); continue
    add(name, "AXTerm test database, received off the air" if direction == "rx" else "AXTerm test database, AXTerm's own transmission", raw)
print("rejected from DB:", rejected, file=sys.stderr)

# 2. Captured fixtures already in the repo
def walk(o, fname, key=""):
    short = fname.split("/")[-1]
    if isinstance(o, dict):
        for k, v in o.items(): walk(v, fname, k)
    elif isinstance(o, list):
        for v in o: walk(v, fname, key)
    elif isinstance(o, str) and (key == "frame_hex" or short == "axterm-onair-frames.json"):
        add(f"{short} {key}", f"AXTermTests/Fixtures/{short}", bytes.fromhex(o))
for f in sorted(glob.glob(REPO + "/AXTermTests/Fixtures/*.json")):
    if "address-corpus" in f: continue
    walk(json.load(open(f)), f)

# 3. Constructed frames, in the byte layout real stacks emit
C = "constructed to AX.25 2.2"
bbs = ("KB5YZB", 7); me = ("K0EPI", 1)
add("SABM via digi", C, frame(bbs, me, [("N0SZ", 2, False)], 0x3F, cmd=True))
add("UA back through digi (H set)", C, frame(me, bbs, [("N0SZ", 2, True)], 0x73, cmd=False))
add("I-frame two digis first repeated", C, frame(me, bbs, [("W0NED", 0, True), ("N0SZ", 2, False)], 0x00, 0xF0, b"Welcome to KB5YZB BBS\r", cmd=True))
add("I-frame N(S)=5 N(R)=3 P", C, frame(bbs, me, [], 0x7A, 0xF0, b"L\r"))
add("RR response F", C, frame(me, bbs, [], 0x71, cmd=False))
add("RNR command", C, frame(bbs, me, [], 0x45))
add("REJ", C, frame(me, bbs, [], 0x69, cmd=False))
add("SREJ", C, frame(me, bbs, [], 0x2D, cmd=False))
add("DISC", C, frame(bbs, me, [], 0x53))
add("DM", C, frame(me, bbs, [], 0x1F, cmd=False))
add("FRMR with info", C, frame(me, bbs, [], 0x87, info=bytes([0x3F, 0x22, 0x01]), cmd=False))
add("XID command", C, frame(bbs, me, [], 0xBF, info=bytes.fromhex("8280000c02020001030201")))
add("TEST command", C, frame(bbs, me, [], 0xF3, info=b"ping"))
add("eight digipeaters, all repeated", C, frame(("APRS", 0), ("N0CALL", 9),
    [(f"DIGI{i}", i, True) for i in range(1, 9)], 0x03, 0xF0, b">max path"))
add("eight digipeaters, none repeated", C, frame(("APRS", 0), ("N0CALL", 10),
    [("WIDE7", 7, False)] * 8, 0x03, 0xF0, b">max path"))
for ssid in range(16):
    add(f"source SSID {ssid}", C, frame(("APRS", 0), ("W1AW", ssid), [("WIDE2", 2, False)], 0x03, 0xF0, b">ssid"))
add("reserved bits zero (V1 style)", C, frame(("CQ", 0), ("K0EPI", 3), [("RELAY", 0, True)], 0x03, 0xF0, b"hello", reserved=0x00))
add("reserved bits zero, no C bits", C, frame(("QST", 0), ("K0EPI", 0), [], 0x03, 0xF0, b"x", cmd=False, reserved=0x00))
add("single-letter destination", C, frame(("X", 0), ("K0EPI", 0), [], 0x03, 0xF0, b"x"))
add("six-digit destination", C, frame(("012345", 0), ("K0EPI", 0), [], 0x03, 0xF0, b"x"))
add("generic destinations and aliases", C, frame(("BEACON", 0), ("N0CALL", 0),
    [("TRACE3", 3, True), ("RFONLY", 0, False), ("NOGATE", 0, False), ("TCPIP", 0, False)], 0x03, 0xF0, b"!"))
add("ID beacon", C, frame(("ID", 0), ("KB5YZB", 7), [], 0x03, 0xF0, b"KB5YZB-7/R BBS"))
add("MAIL destination", C, frame(("MAIL", 0), ("KB5YZB", 1), [], 0x03, 0xF0, b"Mail for: K0EPI"))
add("Mic-E destination, A-K and L/P/Z", C, frame(("AJKLPZ", 0), ("N0CALL", 9), [("WIDE1", 1, False)], 0x03, 0xF0, bytes.fromhex("6070491c6c2039662f60")))
add("Mic-E destination, digits and L/Z", C, frame(("0L9PZL", 0), ("N0CALL", 7), [], 0x03, 0xF0, bytes.fromhex("6070491c6c2039662f60")))
add("Mic-E destination, P-Y", C, frame(("PQRSTY", 0), ("N0CALL", 7), [], 0x03, 0xF0, bytes.fromhex("27704a1c6c2039662f")))
nodes = bytes.fromhex("ff44454e564552968a608e84406e434f53434f2096846ab2b4846ec0ae6082a4a04074424f554c4452ae6082a4a040748c")
add("NET/ROM NODES broadcast", "NODES info from RigFarmWireCompatibilityTests, header constructed", frame(("NODES", 0), ("W0TX", 2), [], 0x03, 0xCF, nodes))
l3 = addr("K0EPI", 1) + addr("W0TX", 2, last=True) + bytes([7, 0x05, 0x01, 0, 0, 0x05]) + b"hello"
add("NET/ROM L3 datagram in I-frame", C, frame(("W0TX", 2), ("K0EPI", 1), [], 0x00, 0xCF, l3))

out = {
    "note": "Frames that must decode identically under the strict AX.25 address rules. "
            "Expected fields come from the decoder as it stood before the rules "
            "(transcribed in the generator), so this file pins that nothing real changed. "
            "Sources: the AXTerm test database (overnight 2026-09-29), the other fixtures "
            "in this folder, and frames constructed to AX.25 2.2 for the connected-mode, "
            "NET/ROM and edge-case shapes the capture lacks.",
    "frames": corpus,
    "rejected": [{"name": n, "frame_hex": h} for n, h in rejected],
}
with open(REPO + "/AXTermTests/Fixtures/ax25-address-corpus.json", "w") as fh:
    json.dump(out, fh, indent=1)
    fh.write("\n")
print(len(corpus), "frames", file=sys.stderr)
