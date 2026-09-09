#!/usr/bin/env python3
"""Transmit AXTerm's frames on the RF rig and record what the channel does.

The frames here are built by this script's own encoder, independently of
AXTerm. Two facts then combine into the proof:

  1. These bytes go on a real modulated channel and a real Xastir answers them
     correctly  ->  the bytes are spec-correct.
  2. `AXTermOnAirTests` asserts AXTerm's production builders emit exactly these
     bytes                                   ->  AXTerm's transmissions are too.

Neither half is worth much alone: AXTerm agreeing with itself proves nothing,
and bytes nobody transmits prove nothing.

    docker compose --profile rfnet up -d
    python3 axterm_onair.py --out ../../AXTermTests/Fixtures/axterm-onair.json
"""
import argparse, json, socket, sys, time
sys.path.insert(0, ".")
from xastir_oracle import ui_frame, deframe, decode, direwolf_decodes, decode_block
from ax25station import kiss_wrap

US, TOCALL, TARGET = "ORACLE-1", "APZAXT", "XASTIR-1"

# Must stay in step with AXTermOnAirTests.frames.
#
# `needle` is a fragment unique to the frame, used to find Direwolf's decode of
# it in the log: every frame here comes from ORACLE-1>APZAXT, so the address
# pair identifies nothing on its own.
FRAMES = [
    ("ping-position",          f":{TARGET:<9}:?APRSP",                    [],           14, "?APRSP"),
    ("query-version",          f":{TARGET:<9}:?VER",                      [],           14, "?VER"),
    ("query-directs",          f":{TARGET:<9}:?APRSD",                    [],           14, "?APRSD"),
    ("query-trace-digipeated", f":{TARGET:<9}:?APRST",                    ["WIDE1-1"],  16, "?APRST"),
    ("message-numbered",       f":{TARGET:<9}:AXTerm on-air proof{{042",  [],           16, "{042"),
    ("beacon-position",        "!3936.70N/10443.90W-AXTerm on-air proof", [],           14, "3936.70N"),
    # The compressed beacon (APRS 1.01 ch.9). AXTerm can transmit it but never
    # had: base-91 is exactly the encoding where an off-by-one in a divisor
    # still produces a plausible-looking frame at the wrong coordinates, so it
    # needs somebody else to say where it landed. Direwolf does, below.
    ("beacon-compressed",      "!/:KoH4#0S-  AAXTerm on-air proof",       [],           14, ":KoH4#0S"),
    # Bruninga's rule: every station in earshot answers a general query after a
    # random 0-120 s spread, so this one needs a window longer than the spread.
    ("general-query",          "?APRS?",                                  [],          135, "?APRS?"),
]


def run(host, port, attempts):
    out = {}
    for name, info, via, listen, needle in FRAMES:
        frame = ui_frame(US, TOCALL, info, via=via)
        rec = {"info": info, "via": via, "frame_hex": frame.hex(),
               "needle": needle, "replies": []}
        for attempt in range(1, attempts + 1):
            sock = socket.create_connection((host, port), timeout=5)
            sock.settimeout(0.5)
            sock.sendall(kiss_wrap(frame))
            print(f"--> {name}: {info!r} via {via}"
                  + (f"  (attempt {attempt})" if attempt > 1 else ""), flush=True)
            buf, t0, seen = b"", time.time(), set()
            while time.time() - t0 < listen:
                try:
                    buf += sock.recv(4096)
                except socket.timeout:
                    continue
                frames, buf = deframe(buf)
                for raw in frames:
                    got = decode(raw)
                    if not got:
                        continue
                    dest, src, vias, payload = got
                    if src == US:                       # our own transmission
                        continue
                    key = (src, tuple(vias), payload)
                    if key in seen:
                        continue
                    seen.add(key)
                    r = {"after_s": round(time.time() - t0, 2),
                         "src": src, "dest": dest, "via": vias,
                         "frame_hex": raw.hex(),
                         "info_ascii": payload.decode("ascii", "replace").strip()}
                    rec["replies"].append(r)
                    print(f"    <-- +{r['after_s']:6.2f}s {src}>{dest} "
                          f"{r['info_ascii']!r}", flush=True)
            sock.close()
            if rec["replies"]:
                break
        rec["attempts"] = attempt
        if not rec["replies"]:
            print("    <-- (nothing)", flush=True)
        out[name] = rec
    return out


ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1")
ap.add_argument("--port", type=int, default=8013, help="8013 = rfnet, 8010 = hub")
ap.add_argument("--attempts", type=int, default=2)
ap.add_argument("--out", default="axterm-onair.json")
ap.add_argument("--frames-out", default="",
                help="also write just name->hex, for AXTermOnAirTests")
args = ap.parse_args()

started = time.time()
results = run(args.host, args.port, args.attempts)

# What a third implementation made of the same frames. Xastir answering proves
# the queries; only a decoder saying where it put us proves the beacons.
log = direwolf_decodes(int(time.time() - started) + 15)
for name, rec in results.items():
    rec["decoded_by_direwolf"] = decode_block(log, f"{US}>{TOCALL}", rec["needle"])
    print(f"    {name:<24} direwolf: {rec['decoded_by_direwolf'][:2]}", flush=True)
json.dump({
    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "asked_as": US, "target": TARGET,
    "channel": "rfnet: 1200-baud AFSK, one Direwolf per station, shared audio bus",
    "note": "AXTerm's own transmissions on a real modulated channel. The frames "
            "are built by TestRig/scripts/axterm_onair.py independently of "
            "AXTerm; AXTermOnAirTests asserts AXTerm emits the same bytes.",
    "frames": results,
}, open(args.out, "w"), indent=2)

if args.frames_out:
    json.dump({k: v["frame_hex"] for k, v in results.items()},
              open(args.frames_out, "w"), indent=2)

answered = sum(1 for v in results.values() if v["replies"])
print(f"\n{answered}/{len(results)} drew a reply -> {args.out}")
