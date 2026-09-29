#!/usr/bin/env python3
"""Put AXTerm's composed objects on the air and record how Direwolf reads them.

AXTerm could only ever *read* objects; it can now transmit them, which means
its encoder has to be right for somebody other than its own parser. Round
tripping through `APRSObjectReport.parse` proves only that one implementation
agrees with itself, and an object name one character short still parses at
home while landing in the wrong field everywhere else.

Same two-part proof as `axterm_onair.py`. This script builds the frames with
its own encoder, transmits them through a real modem, and records Direwolf's
decode. `APRSObjectOnAirTests` then asserts AXTerm's own
`APRSObjectReport.objectInfo` emits exactly these bytes. Neither half rests on
the code under test.

    docker compose --profile rfnet up -d
    python3 axterm_object_onair.py --out ../../AXTermTests/Fixtures/axterm-object-onair.json
"""
import argparse, json, socket, sys, time
sys.path.insert(0, ".")
from xastir_oracle import ui_frame, direwolf_decodes, decode_block
from ax25station import kiss_wrap

US, TOCALL = "ORACLE-1", "APZAXT"

# Fixed so the bytes are reproducible: the same timestamp the Swift test uses.
# 09 Sep 2026 12:00 UTC -> "091200z".
STAMP = "091200z"


def object_info(name, live, lat, lon, table, code, comment=""):
    """`;NAMEXXXXX*DDHHMMz<position><comment>` — nine-character name, one
    state byte, seven-character timestamp, then an ordinary uncompressed
    position. Written from APRS 1.01 ch.11, not from AXTerm."""
    wire = "".join(c for c in name.strip() if c not in "!_;)")[:9].ljust(9)
    d = int(abs(lat)); m = (abs(lat) - d) * 60
    latf = f"{d:02d}{m:05.2f}{'N' if lat >= 0 else 'S'}"
    d = int(abs(lon)); m = (abs(lon) - d) * 60
    lonf = f"{d:03d}{m:05.2f}{'E' if lon >= 0 else 'W'}"
    return f";{wire}{'*' if live else '_'}{STAMP}{latf}{table}{lonf}{code}{comment}"


# (name, info, needle)
FRAMES = [
    ("object-place",
     object_info("ROADCLOSE", True, 39.6117, -104.7317, "/", "-", "US-85 washed out"),
     "ROADCLOSE"),
    # A kill for the same object: one byte different, and the byte that
    # decides whether every receiver on the channel shows it or drops it.
    ("object-kill",
     object_info("ROADCLOSE", False, 39.6117, -104.7317, "/", "-"),
     "ROADCLOSE"),
    # The alternate symbol table, where a wrong table character silently
    # relabels the object as something else entirely.
    ("object-alternate-table",
     object_info("FIRE", True, 39.6000, -104.7000, "\\", "!", "structure fire"),
     "FIRE"),
    # A name longer than nine characters, truncated the way the format
    # requires. Direwolf reporting the truncated name is the proof the
    # truncation is the right one.
    ("object-truncated-name",
     object_info("EVACUATION ROUTE", True, 39.5000, -104.8000, "/", "+"),
     "EVACUATI"),
]


def transmit(host, port, frames):
    sock = socket.create_connection((host, port), timeout=5)
    sock.settimeout(0.5)
    out = []
    for name, info, needle in frames:
        raw = ui_frame(US, TOCALL, info)
        sock.sendall(kiss_wrap(raw))
        print(f"--> {name:<24} {info[:56]!r}", flush=True)
        out.append({"name": name, "info": info, "info_hex": info.encode().hex(),
                    "frame_hex": raw.hex(), "needle": needle})
        time.sleep(3.0)          # half duplex; one at a time
    sock.close()
    return out


ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1")
ap.add_argument("--port", type=int, default=8013)
ap.add_argument("--out", default="axterm-object-onair.json")
args = ap.parse_args()

started = time.time()
frames = transmit(args.host, args.port, FRAMES)
time.sleep(4)
log = direwolf_decodes(int(time.time() - started) + 10)

for rec in frames:
    rec["decoded_by_direwolf"] = decode_block(log, f"{US}>{TOCALL}", rec["needle"])
    print(f"    {rec['name']:<24} "
          f"{'decoded' if rec['decoded_by_direwolf'] else 'NOT DECODED'}: "
          f"{rec['decoded_by_direwolf'][:2]}", flush=True)

json.dump({
    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "stamp": STAMP,
    "channel": "rfnet: 1200-baud AFSK through a real modem, decoded by Direwolf",
    "note": "AXTerm's object encoder, proven against an implementation that is "
            "not AXTerm. Frames built by this script independently; "
            "APRSObjectOnAirTests asserts AXTerm emits the same bytes. "
            "Regenerate with TestRig/scripts/axterm_object_onair.py.",
    "frames": frames,
}, open(args.out, "w"), indent=2)
ok = sum(1 for f in frames if f["decoded_by_direwolf"])
print(f"\n{ok}/{len(frames)} decoded by Direwolf -> {args.out}")
