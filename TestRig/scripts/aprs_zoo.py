#!/usr/bin/env python3
"""Put one frame of every APRS type on the air and record how Direwolf reads it.

AXTerm transmits only positions and messages; objects, telemetry, weather and
Mic-E are parse-only. Those parsers can therefore never be proven by anything
AXTerm sends — something else has to put the frames on the channel and a
different implementation has to agree about what they mean.

That is what this does. Each frame is transmitted through a real modem, and
Direwolf's own APRS parser — a mature implementation that is neither AXTerm nor
Xastir — describes it in its log. `APRSZooTests` then asserts AXTerm's parsers
reach the same conclusion. Where a frame is synthesised rather than captured,
Direwolf accepting it is what validates the synthesis: a malformed frame is
simply not decoded, so the test cannot pass on garbage.

Provenance is recorded per frame. `off-air` frames are real transmissions from
the operator's own channel (K0EPI-7's log, 2026-09-09), reconstructed from the
hex and ASCII in the RX trace.

    docker compose --profile rfnet up -d
    python3 aprs_zoo.py --out ../../AXTermTests/Fixtures/aprs-zoo.json
"""
import argparse, json, socket, subprocess, sys, time
sys.path.insert(0, ".")
from xastir_oracle import ui_frame, deframe, decode, direwolf_decodes, decode_block
from ax25station import kiss_wrap

# (name, source-call, ax25-destination, info bytes, provenance, needle)
#
# `needle` is a printable fragment unique to this frame, used to pick the right
# block out of Direwolf's log: two frames can share a source and destination
# (SIMLA sends both telemetry and status), and matching on the address pair
# alone silently gave the second probe the first one's decode.
#
# The AX.25 destination matters for Mic-E and only for Mic-E: that is where the
# latitude, the message bits and the N/S and E/W signs live (APRS 1.01 ch.10),
# which is why a Mic-E frame cannot be tested from its information field alone.
ZOO = [
    ("mic-e", "WT0R-9", "SYTPZZ",
     bytes.fromhex("60704 91c6c2039662f60224726 7d".replace(" ", ""))
     + b"147.210MHz C100 +060_1\r",
     "off-air: WT0R-9 on K0EPI-7's channel, 2026-09-09", "WT0R-9>SYTPZZ"),

    ("compressed-position", "AD1CT", "APGRWO",
     b'!/:KA74"6#-  C/A=005815Graywolf/0.14.13',
     "off-air: AD1CT (Graywolf) on K0EPI-7's channel, 2026-09-09", "KA74"),

    ("uncompressed-position", "KK0X-10", "APMI04",
     b"@080030z3934.15N/10455.05W-WX3in1Mini U=12.4V.",
     "off-air: KK0X-10 on K0EPI-7's channel, 2026-09-09", "WX3in1Mini"),

    ("object", "METHOD", "APMI04",
     b";147.285CO*111111z3826.78N/10600.65WrT88 R40m repeater",
     "off-air prefix: METHOD's object on K0EPI-7's channel, comment completed", ";147.285CO"),

    ("item", "K0EPI-7", "APZAXT",
     b")AID!3934.15N/10455.05W-incident marker",
     "synthesised to APRS 1.01 ch.11; Direwolf accepting it validates the shape", ")AID!"),

    ("telemetry", "SIMLA", "APMI06",
     b"T#212,185,047,012,075,000,00000000",
     "off-air: SIMLA on K0EPI-7's channel, 2026-09-09", "T#212"),

    ("weather", "N2XGL-1", "APRS",
     b"@080433z4011.90N/10508.94W_000/000g001t065r000p000P000h42b10160",
     "off-air prefix: N2XGL-1 on K0EPI-7's channel, tail completed to ch.12", "t065r000"),

    ("status", "SIMLA", "APMI06",
     b">No APRS-IS ->Digi  080428",
     "off-air: SIMLA on K0EPI-7's channel, 2026-09-09", ">No APRS-IS"),
]


def transmit(host, port, frames):
    sock = socket.create_connection((host, port), timeout=5)
    sock.settimeout(0.5)
    out = []
    for name, src, dest, info, provenance, needle in frames:
        raw = ui_frame(src, dest, info.decode("latin-1"))
        # ui_frame re-encodes text; keep the exact bytes for non-ASCII (Mic-E).
        head = raw[:16]
        raw = head + info
        sock.sendall(kiss_wrap(raw))
        print(f"--> {name:<22} {src}>{dest} {info[:44]!r}", flush=True)
        out.append({"name": name, "src": src, "dest": dest,
                    "frame_hex": raw.hex(), "info_hex": info.hex(),
                    "provenance": provenance, "needle": needle})
        time.sleep(3.0)          # one at a time: the channel is half duplex
    sock.close()
    return out



ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1")
ap.add_argument("--port", type=int, default=8013)
ap.add_argument("--out", default="aprs-zoo.json")
args = ap.parse_args()

started = time.time()
frames = transmit(args.host, args.port, ZOO)
time.sleep(4)
log = direwolf_decodes(int(time.time() - started) + 10)

for rec in frames:
    lines = decode_block(log, f"{rec['src']}>{rec['dest']}", rec["needle"])
    rec["decoded_by_direwolf"] = lines
    status = "decoded" if lines else "NOT DECODED"
    print(f"    {rec['name']:<22} {status}: {lines[:2]}", flush=True)

json.dump({
    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "channel": "rfnet: 1200-baud AFSK, one Direwolf per station, shared audio bus",
    "note": "One frame of every APRS type, transmitted through a real modem and "
            "described by Direwolf's own parser. AXTerm transmits only positions "
            "and messages, so these are the frames its read-only parsers would "
            "otherwise never be tested against by anything but themselves. "
            "Regenerate with TestRig/scripts/aprs_zoo.py.",
    "frames": frames,
}, open(args.out, "w"), indent=2)
ok = sum(1 for f in frames if f["decoded_by_direwolf"])
print(f"\n{ok}/{len(frames)} decoded by Direwolf -> {args.out}")
